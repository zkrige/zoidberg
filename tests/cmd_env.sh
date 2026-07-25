#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/tmp/cmdenv-state-$$"
CONTENT_DIR="/tmp/cmdenv-content-$$"
mkdir -p "$STATE_DIR" "$CONTENT_DIR"
export REPO_DIR STATE_DIR CONTENT_DIR

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/watchers/plugins/cron.sh"

# _export_task_env exports the runtime env contract for dispatched command/pre_check tasks.
_export_task_env
env_line="${CONFIG_FILE}|${CONTENT_DIR}|${SKILLS_DIR}"
expected="${CONTENT_DIR}/config.json|${CONTENT_DIR}|${REPO_DIR}/skills"
[ "$env_line" = "$expected" ] || { echo "FAIL cmd_env: got [$env_line] want [$expected]"; exit 1; }
[ "$APP_DIR" = "$REPO_DIR" ] || { echo "FAIL cmd_env: APP_DIR=[$APP_DIR]"; exit 1; }
[ "$SECRETS_FILE" = "${CONTENT_DIR}/secrets.json" ] || { echo "FAIL cmd_env: SECRETS_FILE=[$SECRETS_FILE]"; exit 1; }

# Wiring check: _cron_dispatch_command and _cron_run_precheck must call _export_task_env.
grep -q '_export_task_env' <(type _cron_dispatch_command) || { echo "FAIL cmd_env: _cron_dispatch_command missing _export_task_env"; exit 1; }
grep -q '_export_task_env' <(type _cron_run_precheck) || { echo "FAIL cmd_env: _cron_run_precheck missing _export_task_env"; exit 1; }

rm -rf "$STATE_DIR" "$CONTENT_DIR"
echo PASS
