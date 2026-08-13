#!/usr/bin/env bash
# error_filter: a task reply that matches the schedule's error_filter regex is
# logged as a failure for self-evolution, even though the dispatch itself
# succeeded (clean reply, empty stderr). Guards the "graceful degradation looks
# like success" blind spot found 2026-08-13 (crashlytics reported "Errors:
# Firebase MCP unavailable" in a clean reply for a week of runs, zero failures
# logged).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/tmp/errfilter-state-$$"
CONTENT_DIR="/tmp/errfilter-content-$$"
mkdir -p "$STATE_DIR" "$CONTENT_DIR"
export REPO_DIR STATE_DIR CONTENT_DIR
DEFAULT_MODEL="sonnet" DEFAULT_EFFORT="medium"
SCHEDULE_FILE="${CONTENT_DIR}/schedule.json"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/watchers/plugins/cron.sh"

fail() { echo "FAIL error_filter: $1"; exit 1; }

# Stub log_failure (the real one lives in lib/evolution.sh and dispatches an
# agent); capture calls instead.
CAPTURE="${STATE_DIR}/log_failure.calls"
log_failure() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$CAPTURE"; }
log() { : ; }

# 1. Parser surfaces error_filter from schedule.json (empty when absent).
cat > "$SCHEDULE_FILE" <<'EOF'
{"tasks":[
  {"name":"with-filter","cron":"* * * * *","prompt_file":"agents/x.txt","enabled":true,"error_filter":"^Errors?: (?!none)|MCP unavailable"},
  {"name":"no-filter","cron":"* * * * *","prompt_file":"agents/y.txt","enabled":true}
]}
EOF
parsed=$(_cron_parse_schedule) || fail "parse rc"
line1=$(printf '%s\n' "$parsed" | sed -n 1p)
line2=$(printf '%s\n' "$parsed" | sed -n 2p)
printf '%s' "$line1" | grep -q 'MCP unavailable' || fail "error_filter not parsed"
seps1=$(printf '%s' "$line1" | tr -cd '\037' | wc -c | tr -d ' ')
seps2=$(printf '%s' "$line2" | tr -cd '\037' | wc -c | tr -d ' ')
[ "$seps1" -eq "$seps2" ] || fail "field count differs with/without error_filter ($seps1 vs $seps2)"

# 2. Matching reply logs task_reported_error.
: > "$CAPTURE"
_cron_check_reported_error "t1" "Triage done.
Errors: Firebase MCP unavailable - cannot mute issues" "unavailable"
grep -q '^task_reported_error|t1|cron|' "$CAPTURE" || fail "matching reply not logged"

# 3. Non-matching reply logs nothing.
: > "$CAPTURE"
_cron_check_reported_error "t2" "All clean, 3 tickets closed." "unavailable"
[ ! -s "$CAPTURE" ] || fail "non-matching reply logged"

# 4. Empty filter logs nothing even on scary output.
: > "$CAPTURE"
_cron_check_reported_error "t3" "Errors: everything is on fire" ""
[ ! -s "$CAPTURE" ] || fail "empty filter logged"

# 5. Wiring: both dispatch paths call the checker.
grep -q '_cron_check_reported_error' <(type _cron_dispatch_botchannel) || fail "_cron_dispatch_botchannel not wired"
grep -q '_cron_check_reported_error' <(type _cron_dispatch_command) || fail "_cron_dispatch_command not wired"

rm -rf "$STATE_DIR" "$CONTENT_DIR"
echo PASS
