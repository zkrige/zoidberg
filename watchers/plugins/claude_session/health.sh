#!/bin/bash

# ---------------------------------------------------------------------------
# claude_session_health_probe - detect a wedged-but-alive session.
#
# claude_session_is_alive only proves the process exists. The observed failure
# mode is a session that stays alive (idle CPU) but silently stops processing
# channel notifications: events POST fine, no `reply` ever lands, every task and
# message hangs. Only an actual round-trip catches it, so post a synthetic event
# and wait a bounded time for its reply file.
#
# Skipped while the session is mid-turn (a real task can legitimately occupy it
# for minutes). Requires consecutive failures before respawning so a single slow
# turn can't trigger a needless restart. Intervals/timeout configurable via
# config.json .session.health_*.
# ---------------------------------------------------------------------------
# _claude_session_transcript_fresh <seconds> - true if the live session wrote to
# its transcript within the last <seconds>. Tells a busy session (still producing
# output) apart from a wedged one (silent) when a health probe times out.
_claude_session_transcript_fresh() {
  local window="$1" newest age
  newest=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$newest" ] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$newest" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$window" ]
}

# _claude_session_resolve_probe_failure - a posted probe went unanswered past its
# timeout. Decide whether that is a genuine wedge (respawn) or a false alarm
# (busy session / expired auth) and act accordingly.
_claude_session_resolve_probe_failure() {
  local timeout="$1" max_strikes="$2"

  # Busy-but-alive: a telegram turn, whatsapp triage, or cron task can occupy the
  # session past the probe timeout without claude_session_is_busy (pane scrape)
  # or the telegram busy-lock catching it (whatsapp/cron don't set that lock, and
  # the pane footer isn't shown between tool calls). If it is still WRITING its
  # transcript within the probe window it is working, not wedged — striking and
  # respawning would abort that in-flight task (false positives respawned real
  # work repeatedly on 2026-07-22 afternoon).
  if _claude_session_transcript_fresh "$timeout"; then
    _HEALTH_PROBE_STRIKES=0
    log "claude-session: probe timed out but transcript active within ${timeout}s - busy, not wedged"
    return 0
  fi

  _HEALTH_PROBE_STRIKES=$(( _HEALTH_PROBE_STRIKES + 1 ))
  log "claude-session: health probe failed (strike ${_HEALTH_PROBE_STRIKES}/${max_strikes})"
  [ "$_HEALTH_PROBE_STRIKES" -ge "$max_strikes" ] || return 0
  _HEALTH_PROBE_STRIKES=0

  # An auth-expired session also fails the probe, but respawning cannot restore a
  # dead OAuth token — it just wedges again on the next probe, looping a respawn
  # (and this notification) every few minutes until the owner runs /login (this
  # flooded the channel overnight on 2026-07-22). claude_session_check_auth
  # already alerts (rate-limited); do not respawn. Normal wedges still respawn.
  if _claude_session_auth_expired; then
    log "claude-session: probe failed but auth is expired - not respawning; awaiting /login"
    return 0
  fi

  log "claude-session: session wedged (no channel reply), respawning"
  notify "♻️ Bot session was wedged (alive but not answering the channel). Auto-respawned."
  # The respawn resumes the conversation (--continue) like any other respawn.
  # Production logs show zero content-caused wedges: every wedge respawn from
  # 2026-08-02 to 2026-08-13 was a post-restart probe false positive (fixed by
  # the spawn grace below), so forcing a fresh session here would have wiped
  # context daily for no benefit. state/.session-fresh-spawn remains as a
  # manual lever for an operator who wants a clean slate.
  claude_session_spawn
}

_HEALTH_PROBE_LAST=0
_HEALTH_PROBE_STRIKES=0
_HEALTH_PROBE_PENDING_RID=""
_HEALTH_PROBE_PENDING_SINCE=0
_HEALTH_PROBE_SWITCHED=0
_HEALTH_PROBE_MODEL=""
_HEALTH_PROBE_EFFORT=""
_HEALTH_PROBE_DEFAULT_MODEL=""
_HEALTH_PROBE_DEFAULT_EFFORT=""

_claude_session_release_probe_model() {
  [ "$_HEALTH_PROBE_SWITCHED" -eq 1 ] || return 0
  claude_session_switch_model "$_HEALTH_PROBE_DEFAULT_MODEL" "$_HEALTH_PROBE_DEFAULT_EFFORT" \
    "$_HEALTH_PROBE_MODEL" "$_HEALTH_PROBE_EFFORT"
  _HEALTH_PROBE_SWITCHED=0
  flock -u 8
}

claude_session_health_probe() {
  local interval timeout max_strikes now
  interval=$(get_config '.session.health_probe_interval' 2>/dev/null)
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=180
  timeout=$(get_config '.session.health_probe_timeout' 2>/dev/null)
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=25
  max_strikes=$(get_config '.session.health_max_strikes' 2>/dev/null)
  [[ "$max_strikes" =~ ^[0-9]+$ ]] || max_strikes=2
  now=$(date +%s)

  if [ -n "$_HEALTH_PROBE_PENDING_RID" ]; then
    local reply_file="${BOT_CHANNEL_REPLIES_DIR}/${_HEALTH_PROBE_PENDING_RID}.txt"
    if [ -f "$reply_file" ]; then
      rm -f "$reply_file"
      _HEALTH_PROBE_PENDING_RID=""
      _HEALTH_PROBE_STRIKES=0
      _claude_session_release_probe_model
      return 0
    fi
    if [ $(( now - _HEALTH_PROBE_PENDING_SINCE )) -ge "$timeout" ]; then
      rm -f "$reply_file" 2>/dev/null
      _HEALTH_PROBE_PENDING_RID=""
      _claude_session_release_probe_model
      _claude_session_resolve_probe_failure "$timeout" "$max_strikes"
    fi
    return 0
  fi

  [ $(( now - _HEALTH_PROBE_LAST )) -ge "$interval" ] || return 0
  if claude_session_is_busy || [ -e "${BUSY_LOCK:-/tmp/claude-telegram.busy}" ]; then
    _HEALTH_PROBE_STRIKES=0
    return 0
  fi

  local probe_model probe_effort default_model default_effort
  default_model=$(_claude_session_persisted_model)
  default_effort=$(_claude_session_persisted_effort)
  probe_model=$(get_config '.session.health_probe_model' 2>/dev/null)
  [ -n "$probe_model" ] && [ "$probe_model" != "null" ] || probe_model="$default_model"
  probe_effort=$(get_config '.session.health_probe_effort' 2>/dev/null)
  [ -n "$probe_effort" ] && [ "$probe_effort" != "null" ] || probe_effort="$default_effort"
  if [ "$probe_model" != "$default_model" ] || [ "$probe_effort" != "$default_effort" ]; then
    if flock -n 8; then
      claude_session_switch_model "$probe_model" "$probe_effort" "$default_model" "$default_effort"
      _HEALTH_PROBE_SWITCHED=1
      _HEALTH_PROBE_MODEL="$probe_model"
      _HEALTH_PROBE_EFFORT="$probe_effort"
      _HEALTH_PROBE_DEFAULT_MODEL="$default_model"
      _HEALTH_PROBE_DEFAULT_EFFORT="$default_effort"
    else
      log "claude-session: model-switch lock timeout for health probe, probing on the active model"
    fi
  fi

  local rid="health-${now}-$$"
  if bot_channel_post "$rid" "telegram" \
       "<channel>Health probe. Reply with exactly: ok</channel>"; then
    _HEALTH_PROBE_PENDING_RID="$rid"
    _HEALTH_PROBE_PENDING_SINCE=$now
    _HEALTH_PROBE_LAST=$now
  else
    _claude_session_release_probe_model
  fi
  return 0
}
