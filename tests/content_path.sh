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

# Task 4: additive `.local.txt` overlay. A full override shadows the shipped
# prompt forever, so every later framework fix silently stops reaching that
# install. `.local` appends instead, and the framework text always ships.
STATE_DIR="/tmp/ct-state-$$"; export STATE_DIR
rm -rf "${CONTENT_DIR}/agents"; mkdir -p "${CONTENT_DIR}/agents"
log() { :; }

# 4a. .local on top of the FRAMEWORK base: merged, framework text first.
printf 'OPERATOR ADDITION\n' > "${CONTENT_DIR}/agents/guardrails.local.txt"
merged="$(framework_prompt guardrails.txt)"
[ "$merged" = "${STATE_DIR}/prompts/guardrails.txt" ] || { echo "FAIL fp-local-path: $merged"; exit 1; }
grep -q 'GUARDRAILS' "$merged" || { echo FAIL fp-local-missing-framework; exit 1; }
grep -q 'OPERATOR ADDITION' "$merged" || { echo FAIL fp-local-missing-addition; exit 1; }
head -1 "$merged" | grep -q 'GUARDRAILS' || { echo FAIL fp-local-order; exit 1; }

# 4b. .local on top of a FULL override: the override is the base, addition still appends.
printf 'MY OWN BASE\n' > "${CONTENT_DIR}/agents/guardrails.txt"
merged="$(framework_prompt guardrails.txt)"
head -1 "$merged" | grep -q 'MY OWN BASE' || { echo FAIL fp-local-override-base; exit 1; }
grep -q 'OPERATOR ADDITION' "$merged" || { echo FAIL fp-local-override-addition; exit 1; }

# 4c. Edits to the addition take effect without a redeploy (regenerated per call).
printf 'CHANGED ADDITION\n' > "${CONTENT_DIR}/agents/guardrails.local.txt"
grep -q 'CHANGED ADDITION' "$(framework_prompt guardrails.txt)" || { echo FAIL fp-local-stale; exit 1; }

# 4d. Unwritable STATE_DIR degrades to the base rather than losing the prompt.
STATE_DIR="/dev/null/nope"
[ "$(framework_prompt guardrails.txt)" = "${CONTENT_DIR}/agents/guardrails.txt" ] || { echo FAIL fp-local-nostate; exit 1; }
# 4e. UNSET STATE_DIR must degrade too, not abort the caller under `set -u`.
unset STATE_DIR
[ "$(framework_prompt guardrails.txt)" = "${CONTENT_DIR}/agents/guardrails.txt" ] || { echo FAIL fp-local-unset-state; exit 1; }
STATE_DIR="/tmp/ct-state-$$"

rm -rf "$CONTENT_DIR" "$STATE_DIR"; echo PASS
