#!/bin/bash
set +e
umask 077
ulimit -n 2048 2>/dev/null
# scheduler.sh - Thin orchestrator. Sources plugins and runs the main loop.
# Runs as PID 1 in the container; Docker restarts it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

STATE_DIR="${REPO_DIR}/state"
LOGS_DIR="${REPO_DIR}/logs"
mkdir -p "$STATE_DIR" "$LOGS_DIR"

CONTENT_DIR="${CONTENT_DIR:-${REPO_DIR}/config}"
SKILLS_DIR="${REPO_DIR}/skills"
export CONTENT_DIR SKILLS_DIR STATE_DIR

# Globals shared with plugins
MAX_CONCURRENT=3
POLL_TIMEOUT=30
SCHEDULE_FILE="$(content_path schedule.json)"
MODELS_FILE="$(content_path models.json)"
DEFAULT_MODEL=$(jq -r '.defaults.model // "sonnet"' "$MODELS_FILE" 2>/dev/null || echo "sonnet")
DEFAULT_EFFORT=$(jq -r '.defaults.effort // "medium"' "$MODELS_FILE" 2>/dev/null || echo "medium")

# Singleton lock: if another instance is alive, just exit (let Docker restart us)
LOCKFILE="/tmp/zoidberg.lock"
if ! ln -s "$$" "$LOCKFILE" 2>/dev/null; then
  old_pid=$(readlink "$LOCKFILE" 2>/dev/null)
  if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
    # Old instance still running, don't fight it
    exit 0
  fi
  # Old instance is dead, claim the lock
  rm -f "$LOCKFILE"
  if ! ln -s "$$" "$LOCKFILE" 2>/dev/null; then
    exit 0
  fi
fi

cleanup() {
  rm -f "$LOCKFILE"
  for plugin in "${PLUGINS[@]}"; do
    type -t "${plugin}_cleanup" >/dev/null 2>&1 && "${plugin}_cleanup"
  done
  kill -- -$$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

HUP_PENDING=0
trap 'HUP_PENDING=1' HUP

# Load config, credentials, claude binary
load_config

# Find a working Claude binary.
CLAUDE_CANDIDATES=(
  "$(command -v claude 2>/dev/null || echo "${HOME}/.local/bin/claude")"
)

pick_claude_bin() {
  for candidate in "${CLAUDE_CANDIDATES[@]}"; do
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  log "FATAL: no working Claude binary found"
  exit 1
}
CLAUDE_BIN=$(pick_claude_bin)

MODIFIABLE_AGENTS=$(ls -1 "$(content_path agents)"/*.txt 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')

# Guardrails - loaded from file, appended with dynamic agent list
GUARDRAILS_FILE="$(framework_prompt guardrails.txt)"
if [ ! -f "$GUARDRAILS_FILE" ]; then
  log "FATAL: guardrails file missing: ${GUARDRAILS_FILE}"
  exit 1
fi
GUARDRAILS="$(cat "$GUARDRAILS_FILE")
- Modifiable agent files: ${MODIFIABLE_AGENTS}"

source "${SCRIPT_DIR}/../lib/evolution.sh"

# Core plugins are the framework itself (transport, scheduler, deploy backstop)
# and always load. Every other plugin is an optional feature, gated on
# `.features.<name>` in the operator's config.json. See docs/ARCHITECTURE.md.
CORE_PLUGINS=" claude_session cron autoupdate "

PLUGINS=()
SKIPPED_FEATURES=()
for plugin_file in "${SCRIPT_DIR}/plugins/"*.sh; do
  [ -f "$plugin_file" ] || continue
  plugin_name="$(basename "$plugin_file" .sh)"
  if [[ "$CORE_PLUGINS" != *" ${plugin_name} "* ]] && ! feature_enabled "$plugin_name"; then
    SKIPPED_FEATURES+=("$plugin_name")
    continue
  fi
  if ! source "$plugin_file"; then
    log "scheduler: failed to source plugin: $(basename "$plugin_file") - skipping"
    continue
  fi
  PLUGINS+=("$plugin_name")
done
[ ${#SKIPPED_FEATURES[@]} -gt 0 ] && log "scheduler: features disabled: ${SKIPPED_FEATURES[*]}"

# Init plugins
for plugin in "${PLUGINS[@]}"; do
  if type -t "${plugin}_init" >/dev/null 2>&1 && ! "${plugin}_init"; then
    log "scheduler: ${plugin}_init failed - plugin may be degraded"
  fi
done

kill_orphaned_mcp

log "scheduler: daemon started (plugins: ${PLUGINS[*]}, poll: ${POLL_TIMEOUT}s)"

# Main loop
LAST_LOOP_EPOCH=$(date +%s)
LAST_ROTATE_HOUR=""

while true; do
  # SIGHUP -> graceful reload via exec self
  if [ "$HUP_PENDING" = "1" ]; then
    log "scheduler: SIGHUP received - reloading"
    for plugin in "${PLUGINS[@]}"; do
      type -t "${plugin}_cleanup" >/dev/null 2>&1 && "${plugin}_cleanup"
    done
    rm -f "$LOCKFILE"
    trap - EXIT
    exec "$0" "$@"
  fi

  # Wake detection
  now_epoch=$(date +%s)
  loop_gap=$(( now_epoch - LAST_LOOP_EPOCH ))
  LAST_LOOP_EPOCH=$now_epoch
  if [ "$loop_gap" -gt $(( POLL_TIMEOUT * 2 )) ]; then
    log "scheduler: wake detected (${loop_gap}s gap)"
    # Re-validate Claude binary (auto-updates happen during sleep)
    CLAUDE_BIN=$(pick_claude_bin)
    kill_orphaned_mcp
    for plugin in "${PLUGINS[@]}"; do
      type -t "${plugin}_on_wake" >/dev/null 2>&1 && "${plugin}_on_wake"
    done
  fi

  # Rotate logs hourly
  current_hour="$(date +%Y%m%d%H)"
  if [ "$current_hour" != "$LAST_ROTATE_HOUR" ]; then
    LAST_ROTATE_HOUR="$current_hour"
    rotate_logs
  fi

  # Tick each plugin
  for plugin in "${PLUGINS[@]}"; do
    "${plugin}_tick"
  done
done
