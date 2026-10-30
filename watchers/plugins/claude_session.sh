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
MODEL_SWITCH_LOCK="${STATE_DIR}/.model-switch.lock"
MODEL_SWITCH_LOCK_TIMEOUT="${MODEL_SWITCH_LOCK_TIMEOUT:-45}"

source "${REPO_DIR}/lib/auto-push.sh"
for _claude_session_part in bot_channel model auth health; do
  source "${REPO_DIR}/watchers/plugins/claude_session/${_claude_session_part}.sh"
done
unset _claude_session_part

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
# _claude_session_continue_flag - emit --continue when the spawn should resume
# the previous conversation. Respawns (deploy SIGHUP, daily container restart)
# pick up where the session left off: the transcript lives on the claude-home
# volume, so it survives recreates and rebuilds. Two exceptions: a fresh spawn
# was explicitly requested via state/.session-fresh-spawn (wedge recovery -
# resuming a wedged conversation can resume the wedge; the marker is consumed
# here), or no prior conversation exists (--continue with nothing to continue
# errors at launch).
# ---------------------------------------------------------------------------
_claude_session_continue_flag() {
  local fresh_marker="${STATE_DIR}/.session-fresh-spawn"
  if [ -f "$fresh_marker" ]; then
    rm -f "$fresh_marker"
    return 0
  fi
  if ls "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl >/dev/null 2>&1; then
    printf -- '--continue'
  fi
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
  local continue_flag
  continue_flag=$(_claude_session_continue_flag)
  [ -n "$continue_flag" ] && log "claude-session: resuming previous conversation (--continue)"
  tmux send-keys -t "$CLAUDE_TMUX_SESSION" \
    "cd /app && exec $CLAUDE_BIN $continue_flag --permission-mode bypassPermissions --model $model --append-system-prompt-file $sysprompt_file --dangerously-load-development-channels server:bot-channel" Enter
}

# ---------------------------------------------------------------------------
# _claude_session_accept_dialog - dismiss the dev-channels warning if it appears
# ---------------------------------------------------------------------------
_claude_session_accept_dialog() {
  local j
  for j in $(seq 1 10); do
    sleep 1
    if tmux capture-pane -t "$CLAUDE_TMUX_SESSION" -p 2>/dev/null | grep -q "Loading development channels"; then
      tmux send-keys -t "$CLAUDE_TMUX_SESSION" "1"
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
  # Clean stale replies and undrained progress updates from the previous run
  rm -f "${BOT_CHANNEL_REPLIES_DIR}"/*.txt 2>/dev/null
  rm -f "${BOT_CHANNEL_REPLIES_DIR}"/*.progress.* 2>/dev/null
  # Bump the generation marker so in-flight bot_channel_wait_reply callers can
  # detect their session was torn down mid-wait (e.g. a SIGHUP reload) and fail
  # fast instead of blocking for the full wall_timeout on a reply that can never
  # arrive, since the request_id was posted to a now-dead session.
  echo "$(date +%s%N)-$$-${RANDOM}" > "${STATE_DIR}/.session-generation"

  # Health-probe grace: give the fresh session one full probe interval before
  # the first probe. _HEALTH_PROBE_LAST starts at 0, so without this the first
  # probe posted immediately after spawn raced claude's startup (dialog accept,
  # MCP handshake), timed out, and the +180s second probe landed strike 2:
  # every daily 02:00 restart produced a false "wedged" respawn at 02:04
  # (2026-08-02..08-13, 6/6 in the logs).
  _HEALTH_PROBE_LAST=$(date +%s)
  _HEALTH_PROBE_STRIKES=0
  _HEALTH_PROBE_PENDING_RID=""

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
# claude_session_apply_pending_model off.
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
  touch "$MODEL_SWITCH_LOCK" 2>/dev/null
  exec 8>"$MODEL_SWITCH_LOCK"
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
