#!/bin/bash
# lib/telegram-process.sh - Telegram plugin message dispatcher, task routing, retry, fallthrough

# ---------------------------------------------------------------------------
# telegram_route_task_name - Rewrite bare/slash task names into /retry <task>
# Mutates the named variable passed as $1 (the msg_text var name).
# ---------------------------------------------------------------------------
telegram_route_task_name() {
  local -n _msg_ref="$1"

  # Bare task name (e.g. "yti", "website stats", "bitbucket-pr") -> route to the
  # task runner via /retry. Owner uses these as shortcuts to force a full agent
  # run instead of falling through to a chat session that may summarise instead
  # of execute. Spaces normalise to hyphens, so "website stats" -> "website-stats".
  if [[ "$_msg_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9\ -]{0,30}$ ]]; then
    local _candidate
    _candidate=$(printf '%s' "$_msg_ref" | tr '[:upper:] ' '[:lower:]-')
    _telegram_route_candidate _msg_ref "$_candidate" "bare task name"
  fi
  # Slashed task name (e.g. "/website-stats") -> same as bare, route to retry.
  # Real commands (/cancel, /status, /opus, ...) are not allowed tasks, so they
  # are never intercepted here.
  if [[ "$_msg_ref" =~ ^/[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$ ]]; then
    _telegram_route_candidate _msg_ref "${_msg_ref#/}" "slash task"
  fi
}

# Rewrite the referenced msg var to "/retry <candidate>" if it is an allowed task.
_telegram_route_candidate() {
  local -n _ref="$1"
  local _candidate="$2" _kind="$3"
  if is_allowed_task "$_candidate"; then
    log "telegram: ${_kind} '${_ref}' -> /retry ${_candidate}"
    _ref="/retry ${_candidate}"
  fi
}

# ---------------------------------------------------------------------------
# telegram_cmd_retry - /retry <task> (rate-limited)
# ---------------------------------------------------------------------------
telegram_cmd_retry() {
  local msg_text="$1"
  [[ "$msg_text" == /retry\ * ]] || return 1
  local retry_task="${msg_text#/retry }"
  _telegram_retry_gates "$retry_task" || return 0
  # Command tasks run the command directly (no Claude), same as the scheduler.
  local retry_command
  retry_command=$(jq -r --arg name "$retry_task" '.tasks[] | select(.name == $name) | .command // ""' "$SCHEDULE_FILE" 2>/dev/null)
  if [ -n "$retry_command" ]; then
    log "telegram: retry '${retry_task}' via command (no Claude)"
    _telegram_retry_command "$retry_task" "$retry_command" &
    return 0
  fi
  local retry_prompt_file="$(content_path "agents/${retry_task}.txt")"
  if [ -f "$retry_prompt_file" ]; then
    _telegram_retry_prompt "$retry_task" "$retry_prompt_file"
  else
    tg_send "Unknown task: ${retry_task}"
  fi
  return 0
}

# /retry guard checks (rate limit, allowed task, path traversal); 1 means abort.
_telegram_retry_gates() {
  local retry_task="$1"
  local running
  running=$(count_claude_processes)
  if [ "$running" -ge "$MAX_CONCURRENT" ]; then
    tg_send "Busy (${running} tasks running). Try again shortly."
    return 1
  fi
  if ! is_allowed_task "$retry_task"; then
    tg_send "Unknown or disallowed task: ${retry_task}"
    return 1
  fi
  case "${retry_task}" in
    *..* | */* )
      tg_send "Invalid task name: ${retry_task}"
      return 1
      ;;
  esac
  return 0
}

# Command-task retry: run the command in REPO_DIR, send stdout (or exit-code fallback).
_telegram_retry_command() {
  local retry_task="$1" retry_command="$2"
  local cmd_to out rc
  cmd_to=$(jq -r --arg name "$retry_task" '.tasks[] | select(.name == $name) | .wall_timeout // ""' "$SCHEDULE_FILE" 2>/dev/null)
  cd "$REPO_DIR" || exit
  out=$(run_logged_command "$retry_task" "$retry_command" "${cmd_to:-${CLAUDE_WALL_TIMEOUT:-1200}}")
  rc=$?
  if [ -n "$out" ]; then
    tg_send "*[${retry_task} - retry]*
${out}"
  else
    tg_send "[${retry_task} - retry] No output (exit ${rc})."
  fi
}

# Prompt-task retry: resolve model/effort, dispatch into the bot channel, notify.
_telegram_retry_prompt() {
  local retry_task="$1" retry_prompt_file="$2"
  local retry_model retry_effort
  retry_model=$(jq -r --arg name "$retry_task" '.tasks[] | select(.name == $name) | .model // "'"${DEFAULT_MODEL}"'"' "$SCHEDULE_FILE" 2>/dev/null)
  retry_effort=$(jq -r --arg name "$retry_task" '.tasks[] | select(.name == $name) | .effort // "'"${DEFAULT_EFFORT}"'"' "$SCHEDULE_FILE" 2>/dev/null)
  # models.json overrides schedule.json (higher priority)
  if [ -f "${MODELS_FILE:-}" ]; then
    local mf_model mf_effort
    mf_model=$(jq -r --arg n "$retry_task" '.tasks[$n].model // empty' "$MODELS_FILE" 2>/dev/null)
    mf_effort=$(jq -r --arg n "$retry_task" '.tasks[$n].effort // empty' "$MODELS_FILE" 2>/dev/null)
    [ -n "$mf_model" ] && retry_model="$mf_model"
    [ -n "$mf_effort" ] && retry_effort="$mf_effort"
  fi
  log "telegram: retrying task '${retry_task}' via bot-channel"
  _telegram_retry_botchannel "$retry_task" "$retry_prompt_file" &
}

# Bot-channel retry run: build prompt, await reply, send filtered/unfiltered output.
_telegram_retry_botchannel() {
  local retry_task="$1" retry_prompt_file="$2"
  # Guardrails live in the session system prompt (see claude_session.sh), not here.
  retry_prompt="$(cat "$retry_prompt_file")"
  response=$(bot_channel_request "cron" "[task=${retry_task}] ${retry_prompt}" "$CLAUDE_WALL_TIMEOUT")
  echo "$response" >> "${LOGS_DIR}/${retry_task}.log"
  if [ -n "$response" ]; then
    local retry_filter
    retry_filter=$(jq -r --arg name "$retry_task" '.tasks[] | select(.name == $name) | .notify_filter // empty' "$SCHEDULE_FILE" 2>/dev/null)
    if [ -n "$retry_filter" ]; then
      if printf '%s' "$response" | grep -qiE "$retry_filter"; then
        tg_send "*[${retry_task} - retry]*
${response}"
      else
        log "scheduler: retry '${retry_task}' output filtered"
      fi
    else
      tg_send "*[${retry_task} - retry]*
${response}"
    fi
  else
    tg_send "[${retry_task} - retry] No output."
  fi
}

# ---------------------------------------------------------------------------
# telegram_dispatch_claude - Implicit feedback, rate-limit, busy lock, run Claude
# ---------------------------------------------------------------------------
# Implicit feedback detection: log a correction if msg matches negation patterns.
_telegram_detect_feedback() {
  local msg_text="$1"
  local _fb_log
  _fb_log=$(telegram_msg_log)
  if [ -f "$_fb_log" ] && [ -s "$_fb_log" ]; then
    local lower_msg
    lower_msg=$(printf '%s' "$msg_text" | tr '[:upper:]' '[:lower:]')
    case "$lower_msg" in
      "no, "*|"no. "*|"wrong"*|"that's wrong"*|"that's not"*|"actually, "*|"correction:"*|"not what i"*|"i meant "*|"i said "*|"you should have"*)
        local fb_session
        fb_session=$(telegram_active_session_name)
        printf '%s\n' "$(jq -nc --arg t "$(date -Iseconds)" --arg m "$msg_text" --arg s "$fb_session" '{ts:$t,msg:$m,session:$s}')" >> "$FEEDBACK_FILE"
        log_failure "correction" "$msg_text"
        log "telegram: implicit feedback logged, evolution triggered"
        ;;
    esac
  fi
}

telegram_dispatch_claude() {
  local msg_text="$1"
  local media_files="$2"

  # Implicit feedback detection (non-blocking, message still processed normally)
  _telegram_detect_feedback "$msg_text"

  # Rate limit: check concurrent processes
  local running
  running=$(count_claude_processes)
  if [ "$running" -ge "$MAX_CONCURRENT" ]; then
    telegram_queue_message "$msg_text" "$media_files"
    return
  fi

  # Atomic busy lock: ln -s fails if file already exists (no TOCTOU race)
  if ! ln -s "$$" "$BUSY_LOCK" 2>/dev/null; then
    telegram_queue_message "$msg_text" "$media_files"
    return
  fi

  local tg_model tg_effort
  _telegram_resolve_model_effort tg_model tg_effort
  _telegram_process_and_drain "$msg_text" "$media_files" "$tg_model" "$tg_effort" &
}

# Resolve model and effort into the two referenced vars: session overrides > defaults.
_telegram_resolve_model_effort() {
  local -n _m="$1" _e="$2"
  _m="$DEFAULT_MODEL"
  _e="$DEFAULT_EFFORT"
  [ -f "$TG_MODEL_FILE" ] && _m=$(cat "$TG_MODEL_FILE")
  [ -f "$TG_EFFORT_FILE" ] && _e=$(cat "$TG_EFFORT_FILE")
}

# Process this message under the busy lock, then drain any queued messages.
_telegram_process_and_drain() {
  local msg_text="$1" media_files="$2" tg_model="$3" tg_effort="$4"
  log "telegram: processing (${tg_model}/${tg_effort}): ${msg_text}"
  telegram_run_claude "$msg_text" "$media_files" "$tg_model" "$tg_effort"
  log "telegram: responded to: ${msg_text}"

  # Drain loop: process queued messages until queue is empty
  while telegram_take_queue; do
    log "telegram: processing queued messages"
    telegram_run_claude "$TAKEN_TEXT" "$TAKEN_MEDIA" "$tg_model" "$tg_effort"
    log "telegram: responded to queued messages"
  done

  rm -f "$BUSY_LOCK"
}

# ---------------------------------------------------------------------------
# telegram_handle_message - Route commands or process via Claude
# Commands: /reset, /opus, /sonnet, /haiku, /low, /medium, /high, /max, /retry
# ---------------------------------------------------------------------------
# Log the inbound message, redacting the OAuth code in "/login <code>".
_telegram_log_received() {
  local _log_text="$1"
  [[ "$1" == "/login "* ]] && _log_text="/login <redacted>"
  log "telegram: received message: ${_log_text}"
}

telegram_handle_message() {
  local msg_text="$1"
  local media_files="$2"

  _telegram_log_received "$msg_text"
  telegram_route_task_name msg_text

  telegram_cmd_cancel "$msg_text" && return
  telegram_cmd_reload "$msg_text" && return
  telegram_cmd_restart "$msg_text" && return
  telegram_cmd_login_start "$msg_text" && return
  telegram_cmd_login_code "$msg_text" && return
  telegram_cmd_status "$msg_text" && return
  telegram_cmd_session "$msg_text" && return
  telegram_cmd_sessions "$msg_text" && return
  telegram_cmd_feedback "$msg_text" && return
  telegram_cmd_reset "$msg_text" && return
  telegram_cmd_model "$msg_text" && return
  telegram_cmd_effort "$msg_text" && return
  telegram_cmd_retry "$msg_text" && return

  telegram_dispatch_claude "$msg_text" "$media_files"
}
