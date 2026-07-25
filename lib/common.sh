#!/usr/bin/env bash
# common.sh - Shared library for Zoidberg hooks and scripts.
# Source this file at the top of any hook or script:
#   source "$(dirname "$0")/../lib/common.sh"

# ---------------------------------------------------------------------------
# Directory references
# ---------------------------------------------------------------------------
# REPO_DIR: root of the Zoidberg repo (parent of lib/).
# Callers should set their own SCRIPT_DIR before sourcing if needed.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# parse_stdin - Read hook JSON from stdin and set HOOK_COMMAND / HOOK_CWD.
# Usage: echo '{"hook_command":"git push","cwd":"/tmp"}' | parse_stdin
# ---------------------------------------------------------------------------
parse_stdin() {
  local input
  input="$(cat)"
  HOOK_COMMAND="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
  HOOK_CWD="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  export HOOK_COMMAND HOOK_CWD
}

# ---------------------------------------------------------------------------
# is_git_push - Returns 0 if HOOK_COMMAND contains "git push" (case insensitive).
# ---------------------------------------------------------------------------
is_git_push() {
  local lower
  lower="$(printf '%s' "$HOOK_COMMAND" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *"git push"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# is_git_commit - Returns 0 if HOOK_COMMAND contains "git commit" (case insensitive).
# ---------------------------------------------------------------------------
is_git_commit() {
  local lower
  lower="$(printf '%s' "$HOOK_COMMAND" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *"git commit"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# match_project <pattern> - Returns 0 if HOOK_CWD contains <pattern> (case insensitive).
# ---------------------------------------------------------------------------
match_project() {
  local pattern="$1"
  local lower_cwd lower_pattern
  lower_cwd="$(printf '%s' "$HOOK_CWD" | tr '[:upper:]' '[:lower:]')"
  lower_pattern="$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')"
  case "$lower_cwd" in
    *"$lower_pattern"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# log <msg> - Append a timestamped message to logs/automations.log.
# ---------------------------------------------------------------------------
log() {
  local msg="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$timestamp" "$msg" >> "${REPO_DIR}/logs/automations.log"
}

# ---------------------------------------------------------------------------
# rotate_logs - Trim log files over MAX_LOG_LINES to keep last KEEP_LINES
# Called periodically from scheduler, not on every log call.
# ---------------------------------------------------------------------------
MAX_LOG_LINES=50000
KEEP_LOG_LINES=10000
rotate_logs() {
  for logfile in "${REPO_DIR}"/logs/*.log; do
    [ -f "$logfile" ] || continue
    local lines
    lines=$(wc -l < "$logfile" 2>/dev/null | tr -d ' ')
    [ -z "$lines" ] && lines=0
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
      tail -"$KEEP_LOG_LINES" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
      log "rotated $(basename "$logfile") from ${lines} to ${KEEP_LOG_LINES} lines"
    fi
  done
}

# ---------------------------------------------------------------------------
# load_config - Read config/config.json (via content_path) and store it in CONFIG.
# ---------------------------------------------------------------------------
load_config() {
  local config_file="$(content_path config.json)"
  if [ ! -f "$config_file" ]; then
    log "ERROR: config.json not found at ${config_file}"
    CONFIG="{}"
    return 1
  fi
  CONFIG="$(cat "$config_file")"
  export CONFIG
}

# ---------------------------------------------------------------------------
# get_config <jq_path> - Extract a value from CONFIG using a jq expression.
# Example: get_config '.projects.myapp.health_url'
# ---------------------------------------------------------------------------
get_config() {
  local jq_path="$1"
  if [ -z "$CONFIG" ]; then
    load_config
  fi
  printf '%s' "$CONFIG" | jq -r "$jq_path"
}

# ---------------------------------------------------------------------------
# feature_enabled <name> - is an optional feature turned on in config.json?
# Optional plugins load only when `.features.<name>` is true. An unlisted
# feature is OFF, except telegram (the default interface) which is ON, so an
# existing install that predates this block keeps its bot. Core plugins
# (see CORE_PLUGINS in scheduler.sh) never consult this.
# See docs/ARCHITECTURE.md for the feature contract.
# ---------------------------------------------------------------------------
feature_enabled() {
  local name="$1" value
  # jq's // treats false as absent, so test for the key with has() instead.
  value="$(get_config "if ((.features // {}) | has(\"${name}\")) then (.features.\"${name}\" | tostring) else \"unset\" end")"
  if [ "$value" = "unset" ]; then
    [ "$name" = "telegram" ]
    return
  fi
  [ "$value" = "true" ]
}

# ---------------------------------------------------------------------------
# load_secrets - Read secrets.json and set SECRETS.
# ---------------------------------------------------------------------------
load_secrets() {
  local secrets_file="$(content_path secrets.json)"
  if [ ! -f "$secrets_file" ]; then
    log "ERROR: secrets.json not found at ${secrets_file}"
    SECRETS="{}"
    return 1
  fi
  chmod 600 "$secrets_file" 2>/dev/null
  SECRETS="$(cat "$secrets_file")"
}

# ---------------------------------------------------------------------------
# get_secret <jq_path> - Extract a value from SECRETS using a jq expression.
# ---------------------------------------------------------------------------
get_secret() {
  local jq_path="$1"
  if [ -z "$SECRETS" ]; then
    load_secrets
  fi
  printf '%s' "$SECRETS" | jq -r "$jq_path"
}

# ---------------------------------------------------------------------------
# content_path <relative> - absolute path to operator content under CONTENT_DIR.
# CONTENT_DIR defaults to ${REPO_DIR}/config (submodule working copy on dev);
# compose overrides it via the /app/config bind-mount in production.
# ---------------------------------------------------------------------------
: "${CONTENT_DIR:=${REPO_DIR}/config}"
content_path() { printf '%s/%s' "$CONTENT_DIR" "$1"; }

# ---------------------------------------------------------------------------
# framework_prompt <name.txt> - resolve a framework behavior-prompt. A copy in
# ${CONTENT_DIR}/agents/ overrides the shipped default in ${REPO_DIR}/agents/.
# ---------------------------------------------------------------------------
framework_prompt() {
  local name="$1"
  if [ -f "${CONTENT_DIR}/agents/${name}" ]; then
    printf '%s/agents/%s' "$CONTENT_DIR" "$name"
  else
    printf '%s/agents/%s' "$REPO_DIR" "$name"
  fi
}

# ---------------------------------------------------------------------------
# render_prompt <file> - cat a prompt file with {{PLACEHOLDER}} tokens replaced
# by per-user values from config.json. Keeps account IDs, workspace names and
# JIDs out of tracked prompt text. Prompts with no placeholders pass through
# unchanged, so this is a safe drop-in for cat.
# ---------------------------------------------------------------------------
render_prompt() {
  local file="$1"
  sed \
    -e "s|{{BITBUCKET_WORKSPACE}}|$(get_config '.bitbucket.workspace')|g" \
    -e "s|{{BITBUCKET_ACCOUNT_ID}}|$(get_config '.bitbucket.account_id')|g" \
    -e "s|{{WHATSAPP_SELF_JID}}|$(get_config '.whatsapp.self_jid')|g" \
    -e "s|{{WHATSAPP_SELF_JID_LEGACY}}|$(get_config '.whatsapp.self_jid_legacy')|g" \
    "$file"
}

# ---------------------------------------------------------------------------
# Allowed scheduled task names - derived from schedule.json dynamically.
# ---------------------------------------------------------------------------
is_allowed_task() {
  local name="$1"
  local schedule="$(content_path schedule.json)"
  [ -f "$schedule" ] || return 1
  jq -e --arg n "$name" '.tasks[] | select(.name == $n)' "$schedule" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# count_claude_processes - count running claude child processes
# ---------------------------------------------------------------------------
count_claude_processes() {
  # Count claude processes in our process group (scheduler + its children)
  pgrep -g "$$" -f "claude" 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# kill_orphaned_mcp - Kill MCP server processes reparented to PID 1
# ---------------------------------------------------------------------------
kill_orphaned_mcp() {
  for orphan_pid in $(pgrep -P 1 -f "mcp.*main\.py" 2>/dev/null); do
    kill "$orphan_pid" 2>/dev/null
  done
}

# ---------------------------------------------------------------------------
# kill_tree - Kill a process and all its descendants
# ---------------------------------------------------------------------------
kill_tree() {
  local pid="$1"
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# run_logged_command <name> <command> <timeout> -> echoes output, returns the command's rc
# ---------------------------------------------------------------------------
run_logged_command() {
  local _name="$1" _command="$2" _timeout="$3"
  local _out _rc
  _out=$(timeout "$_timeout" bash -c "$_command" 2>>"${LOGS_DIR}/${_name}.err.log")
  _rc=$?
  printf '%s\n' "$_out" >> "${LOGS_DIR}/${_name}.log"
  printf '%s' "$_out"
  return $_rc
}

# ---------------------------------------------------------------------------
# notify - Generic notification provider. Plugins register their send function
# by setting NOTIFY_FN. Falls back to log-only if no channel registered.
# ---------------------------------------------------------------------------
NOTIFY_FN=""
notify() {
  if [ -n "$NOTIFY_FN" ]; then
    "$NOTIFY_FN" "$@"
  else
    log "notify (no channel): $1"
  fi
}
