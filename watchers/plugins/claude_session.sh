#!/bin/bash
# plugins/claude-session.sh - Always-on interactive Claude Code session manager.
#
# Owns one persistent tmux session running `claude` in interactive mode with
# the bot-channel MCP server loaded. Other plugins post events to the channel's
# localhost HTTP endpoint instead of spawning `claude -p` subprocesses.
#
# The interactive transport puts usage on the subscription pool rather than the
# Agent SDK credit, which is the entire point of this architecture.
#
# Required globals: REPO_DIR, STATE_DIR, LOGS_DIR, CLAUDE_BIN.

CLAUDE_TMUX_SESSION="${CLAUDE_TMUX_SESSION:-zoidberg}"
CLAUDE_SESSION_LOG="${LOGS_DIR}/claude-session.log"
BOT_CHANNEL_PORT="${BOT_CHANNEL_PORT:-8790}"
BOT_CHANNEL_REPLIES_DIR="${HOME}/.claude/channels/bot-channel/replies"
BOT_CHANNEL_HEALTH_URL="http://127.0.0.1:${BOT_CHANNEL_PORT}/health"
# Transcript dir for the /app project (used to read live context size).
CLAUDE_PROJECT_TRANSCRIPT_DIR="${HOME}/.claude/projects/-app"

# ---------------------------------------------------------------------------
# claude_session_is_alive - tmux session exists and claude pid is alive
# ---------------------------------------------------------------------------
claude_session_is_alive() {
  tmux has-session -t "$CLAUDE_TMUX_SESSION" 2>/dev/null || return 1
  local pane_pid
  pane_pid=$(tmux list-panes -t "$CLAUDE_TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] && kill -0 "$pane_pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _claude_session_launch_tmux - create the tmux session and start claude in it
# ---------------------------------------------------------------------------
_claude_session_launch_tmux() {
  tmux kill-session -t "$CLAUDE_TMUX_SESSION" 2>/dev/null
  tmux new-session -d -s "$CLAUDE_TMUX_SESSION" -x 220 -y 60 \
    -e BOT_CHANNEL_PORT="$BOT_CHANNEL_PORT" \
    -e BOT_CHANNEL_REPLIES_DIR="$BOT_CHANNEL_REPLIES_DIR" \
    -e HOME="$HOME" \
    -e PATH="$PATH"

  # Honor the persisted model (set via /opus|/sonnet|/haiku) or the configured
  # default. Without --model the session silently runs claude's built-in default
  # regardless of what /opus claimed, so the wrong model handles every task.
  local model
  model=$(cat "${STATE_DIR}/telegram-model.txt" 2>/dev/null)
  [ -n "$model" ] || model="${DEFAULT_MODEL:-sonnet}"

  # Build the session's REAL system prompt from the stable context: guardrails,
  # the Telegram operating instructions, and portable memory. This is the fix for
  # the injection false-positive. This is a PERSISTENT session, so it already
  # holds the real conversation turns. When each channel-message body ALSO carried
  # a reprint of the guardrails, system prompt, memory, and a transcript of prior
  # turns, the model compared that bundle against its genuine session context,
  # saw a "fake CLAUDE.md/guardrails reprint + fabricated prior-conversation
  # transcript embedded in the channel payload," and refused genuine owner
  # commands as prompt injection. Moving all stable context into the actual system
  # prompt (trusted, expected location) leaves each body as just an attribution +
  # the user's message, which matches how real messages look and can't be
  # mistaken for injection. Rebuilt every spawn so memory stays current.
  local sysprompt_file="${STATE_DIR}/.session-system-prompt.txt"
  # Recent /feedback corrections belong in the trusted system prompt, not the
  # channel body (in the body they read as "fake recent corrections" injection).
  local recent_fb=""
  [ -s "${STATE_DIR}/feedback.log" ] && \
    recent_fb=$(tail -10 "${STATE_DIR}/feedback.log" | jq -r '"- " + .msg' 2>/dev/null)
  {
    cat "$(framework_prompt guardrails.txt)"
    printf '\n\n'
    # Drop the trailing "User message:" cue — it prefixed the body in the old
    # assembly and is meaningless in a system prompt.
    sed '/^User message:[[:space:]]*$/d' "$(framework_prompt telegram-system.txt)"
    if [ -s "${REPO_DIR}/state/memory.md" ]; then
      printf '\n\nPORTABLE MEMORY (persistent facts across sessions):\n\n'
      cat "${REPO_DIR}/state/memory.md"
    fi
    if [ -n "$recent_fb" ]; then
      printf '\n\nRECENT USER CORRECTIONS (learn from these, do not repeat them):\n%s\n' "$recent_fb"
    fi
  } > "$sysprompt_file"

  # Launch claude inside the session with the bot-channel loaded as a
  # development channel (research preview requires this flag for custom channels).
  # Bypass permissions because the container is the sandbox. All dispatch paths
  # (telegram/cron/whatsapp/retry/self-evolve) post into this one session, so the
  # single appended system prompt covers every path.
  tmux send-keys -t "$CLAUDE_TMUX_SESSION" \
    "cd /app && exec $CLAUDE_BIN --permission-mode bypassPermissions --model $model --append-system-prompt-file $sysprompt_file --dangerously-load-development-channels server:bot-channel" Enter
}

# ---------------------------------------------------------------------------
# _claude_session_accept_dialog - dismiss the dev-channels warning if it appears
# ---------------------------------------------------------------------------
_claude_session_accept_dialog() {
  # Accept the "Loading development channels" warning dialog if it appears
  # (no documented config flag to suppress it; pressing 1+Enter selects
  # "I am using this for local development")
  local j
  for j in $(seq 1 10); do
    sleep 1
    if tmux capture-pane -t "$CLAUDE_TMUX_SESSION" -p 2>/dev/null | grep -q "Loading development channels"; then
      tmux send-keys -t "$CLAUDE_TMUX_SESSION" "1"
      sleep 1
      tmux send-keys -t "$CLAUDE_TMUX_SESSION" Enter
      log "claude-session: accepted development-channels warning dialog"
      break
    fi
  done
}

# ---------------------------------------------------------------------------
# _claude_session_wait_channel - block until the channel HTTP listener is up
# ---------------------------------------------------------------------------
_claude_session_wait_channel() {
  # Wait for channel HTTP listener to come up (bun spawn + MCP handshake ~3-5s)
  local i
  for i in $(seq 1 30); do
    if curl -sf --max-time 1 "http://127.0.0.1:${BOT_CHANNEL_PORT}/" -X POST -d 'x' >/dev/null 2>&1 || \
       curl -s --max-time 1 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${BOT_CHANNEL_PORT}/" -d 'x' 2>/dev/null | grep -qE '^(400|405)$'; then
      log "claude-session: channel HTTP up on port ${BOT_CHANNEL_PORT}"
      return 0
    fi
    sleep 1
  done
  log "claude-session: WARNING channel HTTP did not come up within 30s"
  return 1
}

# ---------------------------------------------------------------------------
# _claude_session_release_interactive_prompt - unblock an unanswerable picker
# ---------------------------------------------------------------------------
_claude_session_release_interactive_prompt() {
  # Nobody is at this pane. If the session renders an interactive option picker
  # to ask the owner something, it blocks until something kills it: observed
  # during /setup, where it sat for 2m49s on a question the owner could never
  # see, then ended the turn without calling `reply`.
  #
  # The guardrails tell it to ask inside `reply` instead, but a prompt is advice.
  # This is the enforcement. Escape cancels the picker and hands control back,
  # and the model answers in text on the same turn.
  #
  # Matches the picker's footer, requiring both halves so ordinary output that
  # merely mentions one phrase cannot trigger it. The development-channels
  # warning is a different dialog that must be ACCEPTED, not cancelled, and is
  # handled by _claude_session_accept_dialog at spawn, so it is excluded here.
  local pane
  pane=$(tmux capture-pane -t "$CLAUDE_TMUX_SESSION" -p 2>/dev/null) || return 0
  case "$pane" in *"Loading development channels"*) return 0 ;; esac
  # An unanswered picker only exists on screen - it reaches the transcript once
  # something answers it - so this one has to scrape the pane. That makes it
  # self-matching: written literally, the pattern matched THIS LINE whenever the
  # bot opened claude_session.sh, which it does routinely because it edits its
  # own code, and the match sends Escape into whatever turn is running. Verified
  # 2026-07-26: the picker phrase occurred exactly once in this repo, on the line
  # that grepped for it. Assembling the pattern keeps the literal off the pane -
  # including out of this comment, which tests/session_self_match.sh enforces.
  local picker="Enter to sel""ect.*Esc to can""cel"
  if printf '%s' "$pane" | grep -q "$picker"; then
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" Escape 2>/dev/null
    log "claude-session: cancelled an interactive prompt - nobody is at the pane to answer it"
  fi
}

# ---------------------------------------------------------------------------
# _claude_session_flags_survived - confirm the live process kept its launch args
# ---------------------------------------------------------------------------
_claude_session_flags_survived() {
  # Claude Code re-execs itself to apply a first-run migration (observed with
  # the flicker-free/fullscreen TUI switch) and does NOT preserve argv. The
  # session then runs with no --model, no --append-system-prompt-file and no
  # bot channel: it answers nothing, and it has no guardrails either.
  #
  # _claude_session_wait_channel cannot see this. The bun child spawned before
  # the re-exec survives it (exec keeps children) and holds port 8790 open, so
  # the port probe reports a healthy channel that the new process is not
  # attached to. Only the process's own arguments settle it.
  #
  # ps -o args= rather than /proc: the legacy macOS dev path has no /proc.
  #
  # When the arguments cannot be read at all, report success. This runs on every
  # tick, so treating "cannot tell" as failure would respawn the session forever
  # on any host where ps is restricted. An unreadable session is left to the
  # health probe, which catches a genuine wedge by round-trip instead.
  local pane_pid args
  pane_pid=$(tmux list-panes -t "$CLAUDE_TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] || return 0
  args=$(ps -o args= -p "$pane_pid" 2>/dev/null)
  [ -n "$args" ] || return 0
  case "$args" in *--dangerously-load-development-channels*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# claude_session_spawn - create tmux session running interactive claude
# ---------------------------------------------------------------------------
claude_session_spawn() {
  log "claude-session: spawning interactive session '${CLAUDE_TMUX_SESSION}'"
  mkdir -p "$BOT_CHANNEL_REPLIES_DIR"
  # Clean stale replies from previous run
  rm -f "${BOT_CHANNEL_REPLIES_DIR}"/*.txt 2>/dev/null
  # Bump the generation marker so in-flight bot_channel_wait_reply callers can
  # detect their session was torn down mid-wait (e.g. a SIGHUP reload) and fail
  # fast instead of blocking for the full wall_timeout on a reply that can never
  # arrive, since the request_id was posted to a now-dead session.
  echo "$(date +%s%N)-$$-${RANDOM}" > "${STATE_DIR}/.session-generation"

  # A migration re-exec fires once and writes the setting it migrated to, so the
  # relaunch lands on an already-migrated config and keeps its flags.
  local attempt
  for attempt in 1 2 3; do
    _claude_session_launch_tmux
    _claude_session_accept_dialog
    _claude_session_wait_channel
    # Measured: the re-exec lands ~2s after the process starts, which is inside
    # the window wait_channel already returns in. Settle past it before judging,
    # or the check races the very thing it is looking for.
    sleep 6
    if _claude_session_flags_survived; then
      [ "$attempt" -gt 1 ] && log "claude-session: relaunch ${attempt} kept its flags"
      return 0
    fi
    log "claude-session: session dropped its launch flags (attempt ${attempt}/3) - relaunching"
  done
  log "claude-session: WARNING session is running without the bot channel, dispatches will not be answered"
  return 1
}

# ---------------------------------------------------------------------------
# bot_channel_post - POST an event into the running Claude session
# Args: request_id  kind  content
# Returns 0 on success
# ---------------------------------------------------------------------------
bot_channel_post() {
  local request_id="$1" kind="$2" content="$3"
  if [ -z "$request_id" ] || [ -z "$content" ]; then
    log "bot_channel_post: missing request_id or content"
    return 1
  fi
  local payload
  payload=$(jq -nc \
    --arg id "$request_id" \
    --arg kind "${kind:-cron}" \
    --arg content "$content" \
    '{request_id: $id, kind: $kind, content: $content}')
  curl -sf --max-time 5 -X POST \
    -H 'content-type: application/json' \
    -d "$payload" \
    "http://127.0.0.1:${BOT_CHANNEL_PORT}/" >/dev/null
}

# ---------------------------------------------------------------------------
# bot_channel_wait_reply - block until reply file appears
# Args: request_id  timeout_seconds
# Echoes reply content to stdout, returns 0 on success, 1 on timeout
# ---------------------------------------------------------------------------
bot_channel_wait_reply() {
  local request_id="$1" timeout="${2:-600}"
  local reply_file="${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt"
  local gen_file="${STATE_DIR}/.session-generation"
  local start_gen
  start_gen=$(cat "$gen_file" 2>/dev/null)
  local start=$SECONDS
  while [ ! -f "$reply_file" ]; do
    if [ $(( SECONDS - start )) -ge "$timeout" ]; then
      log "bot_channel_wait_reply: timeout after ${timeout}s waiting for ${request_id}"
      return 1
    fi
    # The session that would answer this request_id was torn down and
    # respawned (e.g. a SIGHUP reload mid-wait) - the new session has no
    # memory of this request and can never call reply() for it. Fail fast
    # instead of blocking out the full timeout.
    if [ -n "$start_gen" ] && [ "$(cat "$gen_file" 2>/dev/null)" != "$start_gen" ]; then
      log "bot_channel_wait_reply: session respawned while waiting for ${request_id} - failing fast after $(( SECONDS - start ))s"
      return 1
    fi
    sleep 1
  done
  cat "$reply_file"
  rm -f "$reply_file"
}

# ---------------------------------------------------------------------------
# bot_channel_request - post and wait, all in one
# Args: kind  content  [timeout]
# Echoes reply to stdout, returns 0 on success
# ---------------------------------------------------------------------------
bot_channel_request() {
  local kind="$1" content="$2" timeout="${3:-600}"
  local request_id
  request_id="req-$(date +%s)-$$-$RANDOM"
  if ! bot_channel_post "$request_id" "$kind" "$content"; then
    return 1
  fi
  bot_channel_wait_reply "$request_id" "$timeout"
}

# ---------------------------------------------------------------------------
# claude_session_context_tokens - current context size of the live session,
# read from the newest transcript's last usage record. Echoes an integer.
# ---------------------------------------------------------------------------
claude_session_context_tokens() {
  local f
  f=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || { echo 0; return; }
  tail -n 200 "$f" 2>/dev/null \
    | jq -r 'select(.message.usage) | (.message.usage | (.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0))' 2>/dev/null \
    | tail -1
}

# ---------------------------------------------------------------------------
# claude_session_is_busy - true if the session is mid-turn (running a task).
# The TUI footer shows "esc to interrupt" only while a turn is in flight, and
# the footer is always the bottom line of the pane.
#
# Scrape ONLY that bottom window. Grepping the whole pane matched the phrase
# wherever it appeared in rendered CONTENT, which pinned the session "busy"
# forever: on 2026-07-26 the memory-prune turn displayed a state/memory.md diff
# whose text quotes "esc to interrupt" (the note describing this very
# heuristic), so every later poll read busy while the session sat idle. That
# starved the telegram idle-fallback in lib/telegram-run.sh - its idle_streak
# never reached 2, so neither the reply-nudge nor the transcript salvage could
# fire - and the dispatch hung for the full CLAUDE_WALL_TIMEOUT. It also pinned
# claude_session_maybe_clear and claude_session_apply_pending_model off.
#
# Two lines, not one: the last line is the footer and the line above it is the
# input box's border rule, so the window can never reach conversation content.
# ---------------------------------------------------------------------------
claude_session_is_busy() {
  tmux capture-pane -t "$CLAUDE_TMUX_SESSION" -p 2>/dev/null \
    | tail -n 2 \
    | grep -q "esc to interrupt"
}

# ---------------------------------------------------------------------------
# claude_session_last_assistant_uuid - uuid of the newest assistant message
# that carries text in the live transcript (empty if none). Used to detect a
# turn that ended without calling the `reply` tool.
# ---------------------------------------------------------------------------
claude_session_last_assistant_uuid() {
  local f
  f=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  tail -n 1000 "$f" 2>/dev/null \
    | jq -rc 'select(.type=="assistant" and ((.message.content // []) | any(.type=="text"))) | .uuid' 2>/dev/null \
    | tail -1
}

# ---------------------------------------------------------------------------
# claude_session_last_assistant_text - concatenated text of the newest
# text-bearing assistant message in the live transcript. The salvage source
# when the model answered but skipped the `reply` tool.
# ---------------------------------------------------------------------------
claude_session_last_assistant_text() {
  local f
  f=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  tail -n 1000 "$f" 2>/dev/null \
    | jq -rc 'select(.type=="assistant" and ((.message.content // []) | any(.type=="text")))' 2>/dev/null \
    | tail -1 \
    | jq -r '[.message.content[] | select(.type=="text") | .text] | join("\n")' 2>/dev/null
}

# ---------------------------------------------------------------------------
# claude_session_apply_pending_model - relaunch with a model switch that was
# requested while a task was mid-flight. /opus|/sonnet|/haiku drop a marker
# when busy; apply it the moment the session goes idle.
# ---------------------------------------------------------------------------
claude_session_apply_pending_model() {
  local marker="${STATE_DIR}/.session-model-pending"
  [ -f "$marker" ] || return 0
  claude_session_is_busy && return 0
  rm -f "$marker"
  log "claude-session: applying deferred model switch, relaunching"
  claude_session_spawn
}

# ---------------------------------------------------------------------------
# _claude_session_dispatch_outstanding - true if some dispatcher is still
# waiting on a reply the session owes it. claude_session_is_busy only scrapes
# the pane footer ("esc to interrupt"), which reads idle the moment a turn
# backgrounds a long-running command (run_in_background) and returns text
# saying it'll report back later - the assistant has NOT called reply() yet,
# but the pane looks idle in that gap. Root-caused 2026-07-23: torrent-fix
# backgrounded a Sonarr SeasonSearch poll, the turn ended with "I'll wait...
# and report back", the pane read idle 20s later, and /clear wiped the
# session before the background task finished and before reply() was ever
# called - the cron dispatch then hung until its full wall_timeout (1800s).
# Checks every outstanding-dispatch signal in the codebase: cron's per-task
# inflight locks, and the telegram/whatsapp/evolve busy locks (evolve's own
# request is exempt - it's the one calling this).
# ---------------------------------------------------------------------------
_claude_session_dispatch_outstanding() {
  local f
  for f in "${STATE_DIR}"/.*.inflight; do
    [ -f "$f" ] && return 0
  done
  [ -e "${BUSY_LOCK:-/tmp/claude-telegram.busy}" ] && return 0
  [ -e "/tmp/claude-whatsapp-busy" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# claude_session_maybe_clear - reset the shared session's context when it grows
# past a threshold and the session is idle. Tasks are independent (each reads
# its own state from files), so a clean slate between them is correct. This
# caps context well below the server-side long-context rejection that otherwise
# silently halts every dispatch once the session crosses ~160k tokens.
# Threshold is configurable via config.json .session.clear_context_tokens.
# ---------------------------------------------------------------------------
claude_session_maybe_clear() {
  local threshold ctx
  threshold=$(get_config '.session.clear_context_tokens' 2>/dev/null)
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=120000
  ctx=$(claude_session_context_tokens)
  [[ "$ctx" =~ ^[0-9]+$ ]] || return 0
  [ "$ctx" -lt "$threshold" ] && return 0
  if claude_session_is_busy; then
    log "claude-session: context ${ctx} >= ${threshold} but session busy, deferring /clear"
    return 0
  fi
  if _claude_session_dispatch_outstanding; then
    log "claude-session: context ${ctx} >= ${threshold} but a dispatch is still awaiting reply, deferring /clear"
    return 0
  fi
  log "claude-session: context ${ctx} >= ${threshold}, sending /clear"
  tmux send-keys -t "$CLAUDE_TMUX_SESSION" "/clear" Enter
}

# ---------------------------------------------------------------------------
# _claude_session_auth_expired - true if the session's LATEST turn failed with
# the expired-login error. Anthropic returns 401 with a 0 exit code and
# `claude auth status` still reports loggedIn, so the error itself is the only
# reliable signal.
#
# Read the transcript, not the pane. The pane is a rendering surface: it shows
# whatever the session is looking at, so grepping it for a phrase matched this
# very file whenever the bot opened claude_session.sh - which it does routinely,
# since it edits its own code. "Please run /login" appears four times in this
# repo. Same defect that pinned claude_session_is_busy busy forever on
# 2026-07-26; a false positive here alerts the owner that a healthy bot is down.
#
# The transcript records the failure structurally (isApiErrorMessage), which no
# rendered content can forge: source code the session reads arrives as a tool
# result, never as an assistant record carrying that flag. Only the newest
# assistant record counts - an older error the session has since recovered from
# must not read as currently expired.
# ---------------------------------------------------------------------------
_claude_session_auth_expired() {
  local f last
  f=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  last=$(tail -n 200 "$f" 2>/dev/null \
    | jq -rc 'select(.type=="assistant")
              | if (.isApiErrorMessage==true)
                then ([.message.content[]? | .text // ""] | join(" "))
                else "" end' 2>/dev/null \
    | tail -1)
  case "$last" in *"Login expired"*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# claude_session_check_auth - alert the owner when the login has expired. The
# session can't re-login itself (interactive OAuth), so alert at most once an
# hour via Telegram with the re-login command. Reads the transcript, no API call.
# ---------------------------------------------------------------------------
_AUTH_CHECK_LAST=0
claude_session_check_auth() {
  local now; now=$(date +%s)
  [ $(( now - _AUTH_CHECK_LAST )) -ge 120 ] || return 0
  _AUTH_CHECK_LAST=$now
  local marker="${STATE_DIR}/.auth-failure-notified"
  if ! _claude_session_auth_expired; then
    rm -f "$marker"   # healthy: reset so the next failure alerts immediately
    return 0
  fi
  local last; last=$(cat "$marker" 2>/dev/null || echo 0)
  [ $(( now - last )) -ge 3600 ] || return 0
  echo "$now" > "$marker"
  log "claude-session: 401 auth-expired in transcript - alerting via Telegram"
  notify "⚠️ Claude auth expired - the bot is down (401 'Please run /login'). No tasks or replies will work until re-login.

Reply \`/login\` here and follow the two steps. No need to touch the server.
If Telegram itself is not working, fall back to \`./setup.sh login\` on the host."
}

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
  claude_session_spawn
}

_HEALTH_PROBE_LAST=0
_HEALTH_PROBE_STRIKES=0
_HEALTH_PROBE_PENDING_RID=""
_HEALTH_PROBE_PENDING_SINCE=0
# NON-BLOCKING: post a synthetic channel event and check for its reply on later
# ticks, rather than blocking the scheduler loop for the full timeout. The old
# blocking wait added up to `timeout` seconds to every loop iteration (on top of
# the 30s telegram long-poll), delaying cron and message handling; post-then-poll
# keeps each tick cheap.
claude_session_health_probe() {
  local interval timeout max_strikes now
  interval=$(get_config '.session.health_probe_interval' 2>/dev/null)
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=180
  timeout=$(get_config '.session.health_probe_timeout' 2>/dev/null)
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=25
  max_strikes=$(get_config '.session.health_max_strikes' 2>/dev/null)
  [[ "$max_strikes" =~ ^[0-9]+$ ]] || max_strikes=2
  now=$(date +%s)

  # Resolve a probe posted on an earlier tick (non-blocking).
  if [ -n "$_HEALTH_PROBE_PENDING_RID" ]; then
    local reply_file="${BOT_CHANNEL_REPLIES_DIR}/${_HEALTH_PROBE_PENDING_RID}.txt"
    if [ -f "$reply_file" ]; then
      rm -f "$reply_file"
      _HEALTH_PROBE_PENDING_RID=""
      _HEALTH_PROBE_STRIKES=0
      return 0
    fi
    if [ $(( now - _HEALTH_PROBE_PENDING_SINCE )) -ge "$timeout" ]; then
      rm -f "$reply_file" 2>/dev/null
      _HEALTH_PROBE_PENDING_RID=""
      _claude_session_resolve_probe_failure "$timeout" "$max_strikes"
    fi
    return 0
  fi

  # No probe in flight: post a new one once the interval has elapsed. Skip while
  # the session is known-busy (a mid-turn session would fail spuriously); the
  # busy lock is heartbeat-refreshed and self-expires, so a wedge is still caught
  # between turns.
  [ $(( now - _HEALTH_PROBE_LAST )) -ge "$interval" ] || return 0
  if claude_session_is_busy || [ -e "${BUSY_LOCK:-/tmp/claude-telegram.busy}" ]; then
    _HEALTH_PROBE_STRIKES=0
    return 0
  fi

  local rid="health-${now}-$$"
  if bot_channel_post "$rid" "telegram" \
       "<channel>Health probe. Reply with exactly: ok</channel>"; then
    _HEALTH_PROBE_PENDING_RID="$rid"
    _HEALTH_PROBE_PENDING_SINCE=$now
    _HEALTH_PROBE_LAST=$now
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Plugin contract
# ---------------------------------------------------------------------------
claude_session_init() {
  if ! command -v tmux >/dev/null 2>&1; then
    log "claude-session: FATAL tmux not installed"
    return 1
  fi
  if ! command -v bun >/dev/null 2>&1 && [ ! -x /home/claude/.bun/bin/bun ]; then
    log "claude-session: FATAL bun not installed"
    return 1
  fi
  if claude_session_is_alive; then
    log "claude-session: existing session '${CLAUDE_TMUX_SESSION}' still alive, reusing"
    return 0
  fi
  claude_session_spawn
}

claude_session_tick() {
  if ! claude_session_is_alive; then
    log "claude-session: session died, respawning"
    claude_session_spawn
    return
  fi
  # A re-exec can strip the launch flags after the spawn checks have passed. The
  # process stays alive and the port stays bound, so nothing else notices; only
  # the health probe would, three and a half minutes later. Catch it here.
  if ! _claude_session_flags_survived; then
    log "claude-session: live session lost its launch flags (no channel) - respawning"
    claude_session_spawn
    return
  fi
  _claude_session_release_interactive_prompt
  claude_session_apply_pending_model
  claude_session_maybe_clear
  claude_session_check_auth
  claude_session_health_probe
}

claude_session_on_wake() {
  if ! claude_session_is_alive; then
    log "claude-session: session not alive after wake, respawning"
    claude_session_spawn
  fi
}

claude_session_cleanup() {
  tmux kill-session -t "$CLAUDE_TMUX_SESSION" 2>/dev/null
}
