#!/usr/bin/env bash
# End-to-end path-resolution check for the CONTENT_DIR overlay.
# Run from repo root: bash tests/e2e_paths.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT_DIR="$(cd watchers && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
CONTENT_DIR="${CONTENT_DIR:-${REPO_DIR}/config}"
fail=0
# framework prompts resolve into agents/ and exist
for p in guardrails telegram-system prompt-sections memory-prune-prompt self-evolve; do
  f="$(framework_prompt "${p}.txt")"; [ -f "$f" ] || { echo "MISS framework_prompt ${p}: $f"; fail=1; }
done
# every schedule task's content files resolve
while IFS=$'\t' read -r pf pc; do
  [ "$pf" != "-" ] && { [ -f "$(content_path "$pf")" ] || { echo "MISS prompt_file $pf"; fail=1; }; }
  [ "$pc" != "-" ] && { [ -f "$(content_path "$pc")" ] || { echo "MISS pre_check $pc"; fail=1; }; }
done < <(jq -r '.tasks[] | [(.prompt_file//"-"),(.pre_check//"-")] | @tsv' "$(content_path schedule.json)")
# command-referenced config/scripts resolve
for s in $(jq -r '.tasks[].command // empty' "$(content_path schedule.json)" | grep -oE 'scripts/[A-Za-z0-9_.-]+' | sort -u); do
  [ -f "${CONTENT_DIR}/${s}" ] || { echo "MISS command script $s"; fail=1; }
done
[ $fail -eq 0 ] && echo "e2e_paths: PASS" || { echo "e2e_paths: FAIL"; exit 1; }
