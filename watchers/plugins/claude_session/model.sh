#!/bin/bash

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

_claude_session_persisted_model() {
  local m
  m=$(cat "${STATE_DIR}/telegram-model.txt" 2>/dev/null)
  printf '%s' "${m:-${DEFAULT_MODEL:-sonnet}}"
}

_claude_session_persisted_effort() {
  local e
  e=$(cat "${STATE_DIR}/telegram-effort.txt" 2>/dev/null)
  printf '%s' "${e:-${DEFAULT_EFFORT:-medium}}"
}

claude_session_switch_model() {
  local model="$1" effort="$2" current_model="$3" current_effort="$4"
  if [ -n "$model" ] && [ "$model" != "$current_model" ]; then
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" -l -- "/model ${model}"
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" Enter
    sleep 1
  fi
  if [ -n "$effort" ] && [ "$effort" != "$current_effort" ]; then
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" -l -- "/effort ${effort}"
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" Enter
    sleep 1
  fi
}
