#!/bin/bash
# watchers/plugins/cron.sh - Cron engine plugin for the scheduler orchestrator.
# Reads scheduler globals (REPO_DIR, STATE_DIR, LOGS_DIR, GUARDRAILS, MAX_CONCURRENT,
# DEFAULT_MODEL/EFFORT, SCHEDULE_FILE). notify/log/is_allowed_task live in lib/common.sh.

cron_match() {
  local cron_expr="$1"
  local cur_min="${CACHED_MIN:-$(date +%-M)}"
  local cur_hour="${CACHED_HOUR:-$(date +%-H)}"
  local cur_dom="${CACHED_DOM:-$(date +%-d)}"
  local cur_mon="${CACHED_MON:-$(date +%-m)}"
  local cur_dow="${CACHED_DOW:-$(date +%u)}"
  local f_min f_hour f_dom f_mon f_dow
  read -r f_min f_hour f_dom f_mon f_dow <<< "$cron_expr"
  cron_field_match "$f_min" "$cur_min" 60 || return 1
  cron_field_match "$f_hour" "$cur_hour" 24 || return 1
  cron_field_match "$f_dom" "$cur_dom" 31 || return 1
  cron_field_match "$f_mon" "$cur_mon" 12 || return 1
  cron_field_match "$f_dow" "$cur_dow" 7 || return 1
  return 0
}

# Match a step expression (e.g. */5 or 2/3); non-zero means no match.
_cron_field_step() {
  local field="$1" value="$2"
  local base="${field%%/*}"
  local step="${field##*/}"
  [ "$base" = "*" ] && base=0
  { [ -z "$step" ] || [ "$step" -eq 0 ] 2>/dev/null; } && return 1
  [ $(( (value - base) % step )) -eq 0 ] && [ "$value" -ge "$base" ] && return 0
  return 1
}

# Match a comma list of values/ranges (e.g. 1,3-5); non-zero means no match.
_cron_field_list() {
  local field="$1" value="$2"
  local parts part
  IFS=',' read -ra parts <<< "$field"
  for part in "${parts[@]}"; do
    if [[ "$part" == *"-"* ]]; then
      local lo="${part%%-*}"
      local hi="${part##*-}"
      if [ "$value" -ge "$lo" ] && [ "$value" -le "$hi" ]; then
        return 0
      fi
    else
      if [ "$value" -eq "$part" ] 2>/dev/null; then
        return 0
      fi
    fi
  done
  return 1
}

cron_field_match() {
  local field="$1"
  local value="$2"
  local max="$3"
  [ "$field" = "*" ] && return 0
  if [[ "$field" == *"/"* ]]; then
    _cron_field_step "$field" "$value"
    return $?
  fi
  _cron_field_list "$field" "$value"
  return $?
}

# Parse task fields via jq, \x1f-joined (NOT bash IFS-whitespace, so empty fields survive).
_cron_parse_schedule() {
  jq -r --arg dm "$DEFAULT_MODEL" --arg de "$DEFAULT_EFFORT" \
    '.tasks[] | [.name, .cron, .prompt_file, (.enabled|tostring), (.notify_filter // ""), (.model // $dm), (.effort // $de), (if .notify == false then "false" else "true" end), (.wall_timeout // ""), (.pre_check // ""), (.command // "")] | join("\u001f")' \
    "$SCHEDULE_FILE" 2>/dev/null
}

cron_check_tasks() {
  [ -f "$SCHEDULE_FILE" ] || return
  read -r CACHED_MIN CACHED_HOUR CACHED_DOM CACHED_MON CACHED_DOW <<< "$(date +'%-M %-H %-d %-m %u')"
  local task_data rc
  task_data=$(_cron_parse_schedule)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "cron: ERROR - failed to parse schedule file"
    log_failure "schedule_parse" "schedule.json" "cron"
    return
  fi
  # No output with a clean exit means a valid schedule that defines no tasks,
  # which is what a new install ships. Only jq failing is an error; treating
  # "nothing scheduled" as a parse failure logged an error every tick and told
  # the owner their schedule was broken when it was merely empty.
  [ -n "$task_data" ] || return

  while IFS=$'\x1f' read -r name cron prompt_file enabled notify_filter task_model task_effort notify_stdout task_wall_timeout task_pre_check task_command; do
    [ -z "$name" ] && continue
    _cron_apply_models_override
    local state_file="${STATE_DIR}/${name}.last"
    local current_key
    current_key="$(date +%Y%m%d%H%M)"
    _cron_task_gates || continue
    _cron_run_precheck || continue
    _cron_run_task
  done <<< "$task_data"
}

# Concurrency + prompt-file checks, then command- or prompt-dispatch (caller loop vars).
_cron_run_task() {
  local running
  running=$(count_claude_processes)
  if [ "$running" -ge "$MAX_CONCURRENT" ]; then
    log "cron: skipping '${name}' - ${running} processes already running"
    return
  fi
  local full_prompt_file="${CONTENT_DIR}/${prompt_file}"
  if [ -z "$task_command" ] && [ ! -f "$full_prompt_file" ]; then
    log "cron: ERROR - prompt file not found: ${full_prompt_file}"
    return
  fi
  # Deterministic command tasks bypass Claude entirely (see _cron_dispatch_command).
  if [ -n "$task_command" ]; then
    log "cron: dispatching '${name}' via command (no Claude)"
    _cron_dispatch_command "$name" "$task_command" "$task_wall_timeout" \
      "$notify_stdout" "$notify_filter" "$current_key" "$state_file" &
    return
  fi
  _cron_dispatch_prompt "$full_prompt_file"
}

# Prompt task: build prompt, honour in-flight lock, dispatch to bot-channel (caller vars).
_cron_dispatch_prompt() {
  local full_prompt_file="$1"
  local prompt
  # Guardrails live in the session system prompt (see claude_session.sh), not here.
  prompt="$(render_prompt "$full_prompt_file")"
  # In-flight guard: wait_reply giving up does NOT kill the run; the session keeps
  # executing it. Skip re-dispatch while in-flight (lock cleared on reply / INFLIGHT_STALE).
  local inflight_lock="${STATE_DIR}/.${name}.inflight"
  if [ -f "$inflight_lock" ] && \
     [ "$(( $(date +%s) - $(stat -c %Y "$inflight_lock" 2>/dev/null || echo 0) ))" -lt "${INFLIGHT_STALE:-1800}" ]; then
    log "cron: skipping '${name}' - previous dispatch still in-flight"
    return
  fi
  log "cron: dispatching '${name}' via bot-channel"
  _cron_dispatch_botchannel "$name" "$prompt" "$task_wall_timeout" \
    "$notify_stdout" "$notify_filter" "$current_key" "$state_file" "$inflight_lock" &
}

_cron_apply_models_override() {
  if [ -f "$MODELS_FILE" ]; then
    local mf_model mf_effort
    mf_model=$(jq -r --arg n "$name" '.tasks[$n].model // empty' "$MODELS_FILE" 2>/dev/null)
    mf_effort=$(jq -r --arg n "$name" '.tasks[$n].effort // empty' "$MODELS_FILE" 2>/dev/null)
    [ -n "$mf_model" ] && task_model="$mf_model"
    [ -n "$mf_effort" ] && task_effort="$mf_effort"
  fi
}

_cron_gate_prompt_path() {
  case "$prompt_file" in
    agents/*.txt) return 0 ;;
    *)
      if [ -z "$task_command" ]; then
        log "cron: BLOCKED invalid prompt_file path '${prompt_file}'"
        return 1
      fi
      ;;
  esac
  return 0
}

_cron_task_gates() {
  [ "$enabled" = "true" ] || return 1
  if ! is_allowed_task "$name"; then
    log "cron: BLOCKED unknown task '${name}'"
    return 1
  fi
  _cron_gate_prompt_path || return 1
  cron_match "$cron" || return 1
  [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$current_key" ] && return 1
  return 0
}

_cron_run_precheck() {
  if [ -n "$task_pre_check" ] && [ -f "${CONTENT_DIR}/${task_pre_check}" ]; then
    _export_task_env
    if ! bash "${CONTENT_DIR}/${task_pre_check}" >> "${LOGS_DIR}/${name}.log" 2>&1; then
      log "cron: pre_check for '${name}' returned non-zero — skipping"
      return 1
    fi
  fi
  return 0
}

# Runtime env contract exported to every dispatched command/pre_check task.
_export_task_env() {
  export CONTENT_DIR APP_DIR="$REPO_DIR" STATE_DIR SKILLS_DIR="${REPO_DIR}/skills"
  export CONFIG_FILE="$(content_path config.json)"
  export SECRETS_FILE="$(content_path secrets.json)"
}

_cron_dispatch_command() {
  local name="$1" task_command="$2" task_wall_timeout="$3"
  local notify_stdout="$4" notify_filter="$5" current_key="$6" state_file="$7"
  cd "$REPO_DIR" || exit
  _export_task_env
  echo "$current_key" > "$state_file"
  local effective_timeout="${task_wall_timeout:-${CLAUDE_WALL_TIMEOUT:-1200}}"
  local output cmd_rc
  output=$(run_logged_command "$name" "$task_command" "$effective_timeout")
  cmd_rc=$?
  if [ "$cmd_rc" -ne 0 ]; then
    log "cron: command task '${name}' exited ${cmd_rc}"
    log_failure "command_error" "$name" "cron" "rc=${cmd_rc}"
  else
    log "cron: command task '${name}' completed"
  fi
  if [ "$notify_stdout" != "false" ] && [ -n "$output" ]; then
    if [ -z "$notify_filter" ] || printf '%s' "$output" | grep -qiE "$notify_filter"; then
      notify "*[${name}]*
${output}"
    fi
  fi
}

# Bot-channel task: post prompt into the interactive session, await reply, notify.
_cron_dispatch_botchannel() {
  local name="$1" prompt="$2" task_wall_timeout="$3"
  local notify_stdout="$4" notify_filter="$5" current_key="$6" state_file="$7" inflight_lock="$8"
  cd "$REPO_DIR" || exit
  echo "$current_key" > "$state_file"
  local err_log="${LOGS_DIR}/${name}.err.log"
  touch "$err_log" 2>/dev/null
  local err_size_before
  err_size_before=$(wc -c < "$err_log" 2>/dev/null | tr -d ' ')
  local effective_timeout="${task_wall_timeout:-${CLAUDE_WALL_TIMEOUT:-1200}}"
  local request_id="cron-${name}-${current_key}-$$"
  _cron_post "$name" "$request_id" "$prompt" "$inflight_lock" || return
  output=$(_cron_wait_reply "$name" "$request_id" "$effective_timeout" "$inflight_lock")
  echo "$output" >> "${LOGS_DIR}/${name}.log"
  # Log task failures for self-evolution when stderr grew during the run.
  local err_size_after
  err_size_after=$(wc -c < "$err_log" 2>/dev/null | tr -d ' ')
  [ "${err_size_after:-0}" -gt "${err_size_before:-0}" ] && log_failure "task_error" "$name" "cron"
  _cron_notify_result "$name" "$output" "$notify_stdout" "$notify_filter"
}

_cron_post() {
  local name="$1" request_id="$2" prompt="$3" inflight_lock="$4"
  # Lock appears slightly after dispatch; the same-minute state_file check closes the gap.
  : > "$inflight_lock"
  if ! bot_channel_post "$request_id" "cron" "[task=${name}] ${prompt}"; then
    rm -f "$inflight_lock"
    log "cron: task '${name}' failed to post to channel"
    log_failure "channel_post" "$name" "cron"
    return 1
  fi
  return 0
}

_cron_wait_reply() {
  local name="$1" request_id="$2" effective_timeout="$3" inflight_lock="$4"
  local output claude_exit
  output=$(bot_channel_wait_reply "$request_id" "$effective_timeout")
  claude_exit=$?
  if [ $claude_exit -ne 0 ]; then
    # Leave the in-flight lock: the run is still executing and blocks re-dispatch.
    log "cron: task '${name}' timed out or failed"
    log_failure "channel_timeout" "$name" "cron" "timeout=${effective_timeout}"
  else
    rm -f "$inflight_lock"
    log "cron: task '${name}' completed"
  fi
  printf '%s' "$output"
}

_cron_notify_result() {
  local name="$1" output="$2" notify_stdout="$3" notify_filter="$4"
  if [ "$notify_stdout" = "false" ]; then
    log "cron: task '${name}' notify=false, stdout not forwarded (task delivers its own output)"
  elif [ -n "$output" ]; then
    if [ -n "$notify_filter" ]; then
      if printf '%s' "$output" | grep -qiE "$notify_filter"; then
        notify "*[${name}]*
${output}"
      else
        log "cron: task '${name}' output filtered (no match for: ${notify_filter})"
      fi
    else
      notify "*[${name}]*
${output}"
    fi
  fi
}

cron_init() {
  if [ ! -f "$SCHEDULE_FILE" ]; then
    log "cron: WARNING - schedule file not found: ${SCHEDULE_FILE}"
    return 1
  fi
  log "cron: initialized (schedule: ${SCHEDULE_FILE})"
  return 0
}

_CRON_LAST_MIN=""

cron_tick() {
  local cur_min
  cur_min=$(date +%-M)
  if [ "$cur_min" != "$_CRON_LAST_MIN" ]; then
    _CRON_LAST_MIN="$cur_min"
    cron_check_tasks
  fi
}

cron_cleanup() { : ; }
cron_on_wake() { : ; }
