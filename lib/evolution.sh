#!/usr/bin/env bash
# evolution.sh - Self-evolution infrastructure.
# Logs failures and triggers the self-evolve agent to improve prompts/memory.
# Requires globals: REPO_DIR, STATE_DIR, LOGS_DIR, CLAUDE_BIN, GUARDRAILS

FAILURES_FILE="${STATE_DIR}/failures.jsonl"
EVOLVE_LOCK="/tmp/claude-self-evolve.busy"
EVOLVE_STAMP="${STATE_DIR}/evolve-last.epoch"

# ---------------------------------------------------------------------------
# log_failure - Log a failure event for self-evolution
# ---------------------------------------------------------------------------
log_failure() {
  local type="$1"
  local input="$2"
  local ctx="${3:-unknown}"
  local details="${4:-}"
  local json
  json=$(jq -nc --arg t "$(date -Iseconds)" --arg type "$type" \
    --arg input "$input" --arg ctx "$ctx" --arg details "$details" \
    '{ts:$t,type:$type,input:$input,ctx:$ctx} | if $details != "" then . + {details:$details} else . end') || {
    echo "evolution: jq failed for log_failure type=$type" >&2
    return 1
  }
  printf '%s\n' "$json" >> "$FAILURES_FILE"
  # Auto-trigger self-evolution on every failure
  trigger_evolution &
}

# ---------------------------------------------------------------------------
# trigger_evolution - Run the self-evolve agent in background
# ---------------------------------------------------------------------------
trigger_evolution() {
  # Rate limit: at most once per cooldown window. Failures cluster (and a jammed
  # session can fire log_failure dozens of times), so without this self-evolve
  # floods the shared session with dispatches. Failures still accumulate in
  # failures.jsonl; the next eligible run processes the whole batch.
  local now last cooldown
  now=$(date +%s)
  cooldown=$(get_config '.evolution.cooldown_seconds' 2>/dev/null)
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=10800
  last=$(cat "$EVOLVE_STAMP" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ $(( now - last )) -lt "$cooldown" ]; then
    return
  fi

  # Skip if already running. EXIT trap guarantees the lock is removed on
  # crash/SIGTERM/reboot; without it a killed run orphans the lock forever
  # and silently blocks every future evolution trigger.
  ln -s "$$" "$EVOLVE_LOCK" 2>/dev/null || return
  trap 'rm -f "$EVOLVE_LOCK"' EXIT INT TERM
  printf '%s\n' "$now" > "$EVOLVE_STAMP"

  log "evolution: triggered"

  local evolve_prompt_file="$(framework_prompt self-evolve.txt)"
  if [ ! -f "$evolve_prompt_file" ]; then
    log "evolution: self-evolve.txt not found, skipping"
    rm -f "$EVOLVE_LOCK"
    return
  fi

  # Guardrails live in the session system prompt (see claude_session.sh), not here.
  local evolve_prompt="$(cat "$evolve_prompt_file")"

  cd "$REPO_DIR"

  # Read model/effort: models.json base, overridden by evolve-config.json (temporary self-upgrade)
  local evolve_model="sonnet" evolve_effort="medium"
  if [ -f "${MODELS_FILE:-}" ]; then
    local mf_model mf_effort
    mf_model=$(jq -r '.evolution.model // empty' "$MODELS_FILE" 2>/dev/null)
    mf_effort=$(jq -r '.evolution.effort // empty' "$MODELS_FILE" 2>/dev/null)
    [ -n "$mf_model" ] && evolve_model="$mf_model"
    [ -n "$mf_effort" ] && evolve_effort="$mf_effort"
  fi
  local evolve_config="${STATE_DIR}/evolve-config.json"
  if [ -f "$evolve_config" ]; then
    local ec_model ec_effort
    ec_model=$(jq -r '.model // empty' "$evolve_config" 2>/dev/null)
    ec_effort=$(jq -r '.effort // empty' "$evolve_config" 2>/dev/null)
    [ -n "$ec_model" ] && evolve_model="$ec_model"
    [ -n "$ec_effort" ] && evolve_effort="$ec_effort"
  fi

  local output rc
  local evolve_request_id="evolve-$(date +%s)-$$"
  if ! bot_channel_post "$evolve_request_id" "cron" "[task=self-evolve] ${evolve_prompt}"; then
    log "evolution: failed to post to bot-channel"
    rm -f "$EVOLVE_LOCK"
    return
  fi
  output=$(bot_channel_wait_reply "$evolve_request_id" 1200)
  rc=$?

  if [ $rc -ne 0 ]; then
    log "evolution: channel reply timeout"
  elif [ -n "$output" ]; then
    echo "$output" >> "${LOGS_DIR}/self-evolve.log"
    log "evolution: completed: $(printf '%s' "$output" | head -c 100)"
  fi

  rm -f "$EVOLVE_LOCK"
}
