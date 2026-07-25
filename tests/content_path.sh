#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_DIR}/lib/common.sh"
CONTENT_DIR="/tmp/ct-$$"; mkdir -p "$CONTENT_DIR/agents"
export REPO_DIR CONTENT_DIR
# content_path
[ "$(content_path schedule.json)" = "${CONTENT_DIR}/schedule.json" ] || { echo FAIL content_path; exit 1; }
# framework_prompt: falls back to REPO_DIR when no override
[ "$(framework_prompt guardrails.txt)" = "${REPO_DIR}/agents/guardrails.txt" ] || { echo FAIL fp-default; exit 1; }
# framework_prompt: content override wins when present
touch "${CONTENT_DIR}/agents/guardrails.txt"
[ "$(framework_prompt guardrails.txt)" = "${CONTENT_DIR}/agents/guardrails.txt" ] || { echo FAIL fp-override; exit 1; }
# Task 2: load_config / is_allowed_task read from CONTENT_DIR
echo '{"tasks":[{"name":"demo"}]}' > "$CONTENT_DIR/schedule.json"
echo '{"git":{"user_name":"x"}}' > "$CONTENT_DIR/config.json"
load_config; [ "$(get_config '.git.user_name')" = "x" ] || { echo FAIL load_config; exit 1; }
is_allowed_task demo || { echo FAIL is_allowed_task; exit 1; }
is_allowed_task nope && { echo FAIL is_allowed_task_neg; exit 1; } || true

# Task 3: framework_prompt for a second prompt name, default + override
[ "$(framework_prompt telegram-system.txt)" = "${REPO_DIR}/agents/telegram-system.txt" ] || { echo FAIL fp2-default; exit 1; }
touch "${CONTENT_DIR}/agents/telegram-system.txt"
[ "$(framework_prompt telegram-system.txt)" = "${CONTENT_DIR}/agents/telegram-system.txt" ] || { echo FAIL fp2-override; exit 1; }

rm -rf "$CONTENT_DIR"; echo PASS
