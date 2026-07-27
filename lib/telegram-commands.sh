#!/bin/bash
# lib/telegram-commands.sh - Telegram plugin lighter command handlers

# telegram_cmd_cancel - /cancel: interrupt the running Claude session
telegram_cmd_cancel() {
  local msg_text="$1"
  [[ "$msg_text" == "/cancel" ]] || return 1
  if [ -f "$CLAUDE_PID_FILE" ]; then
    local cancel_id
    cancel_id=$(cat "$CLAUDE_PID_FILE")
    # Send Escape to the interactive Claude session to interrupt current task
    tmux send-keys -t "$CLAUDE_TMUX_SESSION" Escape 2>/dev/null
    # Write an empty reply so the waiting orchestrator unblocks
    local cancel_reply="${BOT_CHANNEL_REPLIES_DIR}/${cancel_id}.txt"
    printf '[Cancelled by user]' > "$cancel_reply"
    local busy_pid
    busy_pid=$(readlink "$BUSY_LOCK" 2>/dev/null)
    [ -n "$busy_pid" ] && kill -- -"$busy_pid" 2>/dev/null
    rm -f "$CLAUDE_PID_FILE" "$BUSY_LOCK" "$CURRENT_TASK_FILE"
    tg_send "Cancelled."
    log "telegram: cancelled running task (request_id: ${cancel_id})"
  else
    tg_send "Nothing running."
  fi
  telegram_drain_queue
  return 0
}

# telegram_cmd_reload - /reload: in-place code reload via SIGHUP to PID 1
telegram_cmd_reload() {
  local msg_text="$1"
  [[ "$msg_text" == "/reload" ]] || return 1
  tg_send "Reloading scheduler (SIGHUP to PID 1)..."
  log "telegram: /reload requested"
  kill -HUP 1
  return 0
}

# telegram_cmd_restart - /restart: exit PID 1 so Docker respawns container
telegram_cmd_restart() {
  local msg_text="$1"
  [[ "$msg_text" == "/restart" ]] || return 1
  tg_send "Restarting container..."
  log "telegram: /restart requested"
  ( sleep 2; kill -TERM 1 ) &
  disown
  return 0
}

# telegram_cmd_login_start - /login: start OAuth login, return auth URL.
# The poll and verdict live in lib/claude-login.sh, shared with setup.sh.
telegram_cmd_login_start() {
  local msg_text="$1"
  [[ "$msg_text" == "/login" ]] || return 1
  local login_url
  if login_url=$(claude_login_start); then
    tg_send "Open this, approve, then reply: /login <code>
The code expires after a few minutes, so send it while it is fresh.

${login_url}"
    log "telegram: /login started, sent auth URL"
  else
    tg_send "Could not start login (no URL after ${CLAUDE_LOGIN_URL_TIMEOUT}s). Try /login again."
    log "telegram: /login produced no URL"
  fi
  return 0
}

# _telegram_login_cred_expiry - Read expiresAt (epoch ms) from credentials file
_telegram_login_cred_expiry() {
  local cred_file="${HOME}/.claude/.credentials.json"
  local exp
  exp=$(jq -r '(.claudeAiOauth.expiresAt // .expiresAt) // 0' "$cred_file" 2>/dev/null)
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=0
  printf '%s' "$exp"
}

# telegram_cmd_login_code - /login <code>: submit the pasted OAuth code
telegram_cmd_login_code() {
  local msg_text="$1"
  [[ "$msg_text" == "/login "* ]] || return 1
  if ! tmux has-session -t "$CLAUDE_LOGIN_SESSION" 2>/dev/null; then
    tg_send "No login in progress. Send /login first."
    return 0
  fi
  if claude_login_submit "${msg_text#/login }" _telegram_login_cred_expiry; then
    rm -f "${STATE_DIR}/.auth-failure-notified"
    tmux kill-session -t "$CLAUDE_TMUX_SESSION" 2>/dev/null
    tg_send "Logged in. Restarting the bot session with fresh credentials, give it ~30s."
    log "telegram: /login success, respawning session"
  else
    tg_send "Login did not complete. ${CLAUDE_LOGIN_REASON} Send /login for a fresh URL."
    log "telegram: /login failed: ${CLAUDE_LOGIN_REASON}"
  fi
  return 0
}

# _telegram_status_run_line - "Running: <task>" or "Idle"
_telegram_status_run_line() {
  if [ -f "$CURRENT_TASK_FILE" ] && [ -f "$BUSY_LOCK" ]; then
    printf 'Running: %s' "$(cat "$CURRENT_TASK_FILE")"
  else
    printf 'Idle'
  fi
}

# _telegram_status_queue_line - "\nQueued: N message(s)" when queue non-empty
_telegram_status_queue_line() {
  [ -f "$QUEUE_FILE" ] || return 0
  local qlen
  qlen=$(jq 'length' "$QUEUE_FILE" 2>/dev/null || echo 0)
  [ "$qlen" -gt 0 ] && printf '\nQueued: %s message(s)' "$qlen"
  return 0
}

# _telegram_status_model_line - "\nModel: <m>, effort: <e>"
_telegram_status_model_line() {
  local cur_model="$DEFAULT_MODEL" cur_effort="$DEFAULT_EFFORT"
  [ -f "$TG_MODEL_FILE" ] && cur_model=$(cat "$TG_MODEL_FILE")
  [ -f "$TG_EFFORT_FILE" ] && cur_effort=$(cat "$TG_EFFORT_FILE")
  printf '\nModel: %s, effort: %s' "$cur_model" "$cur_effort"
}

# _telegram_status_session_line - "\nSession: <name> (N exchanges|new)"
_telegram_status_session_line() {
  local sess_name _status_log
  sess_name=$(telegram_active_session_name)
  _status_log=$(telegram_msg_log)
  if [ -f "$_status_log" ] && [ -s "$_status_log" ]; then
    local _exchange_count
    _exchange_count=$(wc -l < "$_status_log" 2>/dev/null | tr -d ' ')
    printf '\nSession: %s (%s exchanges)' "$sess_name" "$_exchange_count"
  else
    printf '\nSession: %s (new)' "$sess_name"
  fi
}

# _telegram_status_procs_line - "\nClaude processes: N" when any running
_telegram_status_procs_line() {
  local procs
  procs=$(count_claude_processes)
  [ "$procs" -gt 0 ] && printf '\nClaude processes: %s' "$procs"
  return 0
}

# telegram_cmd_status - /status: show bot state
telegram_cmd_status() {
  local msg_text="$1"
  [[ "$msg_text" == "/status" ]] || return 1
  local status_lines=""
  status_lines="$(_telegram_status_run_line)"
  status_lines="${status_lines}$(_telegram_status_queue_line)"
  status_lines="${status_lines}$(_telegram_status_model_line)"
  status_lines="${status_lines}$(_telegram_status_session_line)"
  status_lines="${status_lines}$(_telegram_status_procs_line)"
  tg_send "$status_lines"
  return 0
}

# telegram_cmd_session - /session <name>: switch to named session
telegram_cmd_session() {
  local msg_text="$1"
  [[ "$msg_text" == /session\ * ]] || return 1
  local new_session_name="${msg_text#/session }"
  new_session_name=$(printf '%s' "$new_session_name" | tr -cd 'a-zA-Z0-9-')
  if [ -z "$new_session_name" ]; then
    tg_send "Usage: /session <name>"
    return 0
  fi
  echo "$new_session_name" > "$ACTIVE_SESSION_FILE"
  local _target_log="${SESSIONS_DIR}/${new_session_name}-messages.jsonl"
  if [ -f "$_target_log" ] && [ -s "$_target_log" ]; then
    local _target_count
    _target_count=$(wc -l < "$_target_log" 2>/dev/null | tr -d ' ')
    tg_send "Switched to session: ${new_session_name} (${_target_count} exchanges)"
  else
    tg_send "Switched to session: ${new_session_name} (new)"
  fi
  log "telegram: switched session to ${new_session_name}"
  return 0
}

# telegram_cmd_sessions - /sessions: list all sessions
telegram_cmd_sessions() {
  local msg_text="$1"
  [[ "$msg_text" == "/sessions" ]] || return 1
  local current_name
  current_name=$(telegram_active_session_name)
  local list="Sessions:"
  for sf in "$SESSIONS_DIR"/*-messages.jsonl; do
    [ -f "$sf" ] || continue
    local sname
    sname=$(basename "$sf" -messages.jsonl)
    local _sf_count
    _sf_count=$(wc -l < "$sf" 2>/dev/null | tr -d ' ')
    if [ "$sname" = "$current_name" ]; then
      list="${list}
* ${sname} (active, ${_sf_count} exchanges)"
    else
      list="${list}
  ${sname} (${_sf_count} exchanges)"
    fi
  done
  tg_send "$list"
  return 0
}

# telegram_cmd_feedback - /feedback <text> or /feedback clear
telegram_cmd_feedback() {
  local msg_text="$1"
  [[ "$msg_text" == /feedback\ * ]] || return 1
  local fb_text="${msg_text#/feedback }"
  if [ "$fb_text" = "clear" ]; then
    rm -f "$FEEDBACK_FILE"
    tg_send "Feedback log cleared."
    log "telegram: feedback cleared"
  else
    local fb_session
    fb_session=$(telegram_active_session_name)
    printf '%s\n' "$(jq -nc --arg t "$(date -Iseconds)" --arg m "$fb_text" --arg s "$fb_session" '{ts:$t,msg:$m,session:$s}')" >> "$FEEDBACK_FILE"
    tg_send "Feedback logged."
    log "telegram: feedback logged: ${fb_text}"
  fi
  return 0
}

# telegram_cmd_reset - /reset: reset current session only
telegram_cmd_reset() {
  local msg_text="$1"
  [[ "$msg_text" == "/reset" ]] || return 1
  local reset_name
  reset_name=$(telegram_active_session_name)
  rm -f "$QUEUE_FILE" "$TG_MODEL_FILE" "$TG_EFFORT_FILE"
  rm -f "${SESSIONS_DIR}/${reset_name}-messages.jsonl" "$PRUNE_COUNTER_FILE"
  tg_send "Session '${reset_name}' reset. Next message starts fresh."
  log "telegram: session '${reset_name}' reset"
  return 0
}

# telegram_cmd_model - /opus, /sonnet, /haiku: switch model for this session
telegram_cmd_model() {
  local msg_text="$1"
  [[ "$msg_text" =~ ^/(opus|sonnet|haiku)$ ]] || return 1
  local new_model="${BASH_REMATCH[1]}"
  echo "$new_model" > "$TG_MODEL_FILE"
  local cur_effort="$DEFAULT_EFFORT"
  [ -f "$TG_EFFORT_FILE" ] && cur_effort=$(cat "$TG_EFFORT_FILE")
  # The persistent session fixes its model at launch, so a switch only takes
  # effect on relaunch. Reload now if idle; otherwise mark it pending and let
  # claude_session_tick apply it the moment the current task finishes.
  if claude_session_is_busy; then
    touch "${STATE_DIR}/.session-model-pending"
    tg_send "Model set to ${new_model}, effort: ${cur_effort}. Applies after the current task finishes. /reset to restore defaults."
    log "telegram: model switched to ${new_model} (deferred, session busy)"
  else
    claude_session_spawn
    tg_send "Model: ${new_model}, effort: ${cur_effort}. Session reloaded. /reset to restore defaults."
    log "telegram: model switched to ${new_model}, session relaunched"
  fi
  return 0
}

# telegram_cmd_effort - /low, /medium, /high, /max: switch effort for session
telegram_cmd_effort() {
  local msg_text="$1"
  [[ "$msg_text" =~ ^/(low|medium|high|max)$ ]] || return 1
  local new_effort="${BASH_REMATCH[1]}"
  echo "$new_effort" > "$TG_EFFORT_FILE"
  local cur_model="$DEFAULT_MODEL"
  [ -f "$TG_MODEL_FILE" ] && cur_model=$(cat "$TG_MODEL_FILE")
  tg_send "Model: ${cur_model}, effort: ${new_effort}. /reset to restore defaults."
  log "telegram: effort switched to ${new_effort}"
  return 0
}
