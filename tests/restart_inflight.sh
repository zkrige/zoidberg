#!/usr/bin/env bash
# 2026-08-01: the 04:00 host restart landed while a Telegram message was
# mid-dispatch. The container came back with a memory-less tmux session, and
# _telegram_recover_crash replayed the orphaned state/telegram-in-progress.json
# into it, producing a nonsense reply to a message that assumed prior context.
# scheduled-restart.sh now waits on that marker - and on cron.sh's per-task
# state/.<task>.inflight locks - and skips the day if they will not clear.
# Run from repo root: bash tests/restart_inflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/scheduled-restart.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# A relocated copy of the script with its own state/ tree, plus a docker stub
# that records the command instead of running one.
REPO="${TMP}/repo"
mkdir -p "${REPO}/scripts" "${REPO}/state" "${TMP}/bin"
cp "$SCRIPT" "${REPO}/scripts/"
cat > "${TMP}/bin/docker" <<'EOF'
#!/bin/bash
echo "$@" >> "$DOCKER_LOG"
EOF
chmod +x "${TMP}/bin/docker"

MARKER="${REPO}/state/telegram-in-progress.json"
CRON_MARKER="${REPO}/state/.daily-brief.inflight"
CRON_MARKER2="${REPO}/state/.invoice-filer.inflight"
DOCKER_LOG="${TMP}/docker.log"

run() { # <interval> <max> -> stdout+stderr, sets RC and truncates the docker log
  : > "$DOCKER_LOG"
  set +e
  OUT="$(PATH="${TMP}/bin:$PATH" DOCKER_LOG="$DOCKER_LOG" \
    RESTART_WAIT_INTERVAL="$1" RESTART_WAIT_MAX="$2" \
    bash "${REPO}/scripts/scheduled-restart.sh" 2>&1)"
  RC=$?
  set -e
}

check() { # <label> <expected> <got>
  if [ "$2" = "$3" ]; then echo "  ok $1"
  else echo "  FAIL $1: want [$2] got [$3]"; fail=1; fi
}

restarted() { grep -c 'restart zoidberg' "$DOCKER_LOG" | tr -d ' '; }
logged() { # <label> <substring>
  case "$OUT" in
    *"$2"*) echo "  ok $1" ;;
    *) echo "  FAIL $1: no [$2] in: $OUT"; fail=1 ;;
  esac
}
clear_markers() { rm -f "$MARKER" "$CRON_MARKER" "$CRON_MARKER2"; }

echo "idle: restarts immediately"
clear_markers
run 1 2
check "docker restart issued" 1 "$(restarted)"
check "exit 0" 0 "$RC"

echo "turn in flight: skips the day instead of restarting"
clear_markers
echo '{"text":"hello","media":""}' > "$MARKER"
run 1 2
check "no docker restart" 0 "$(restarted)"
check "exit 0 (skip is not a failure)" 0 "$RC"
logged "logged the skip" "SKIPPING restart"
logged "named the Telegram turn" "Telegram turn"

echo "turn finishes during the wait: restarts once it clears"
clear_markers
echo '{"text":"hello","media":""}' > "$MARKER"
( sleep 2; rm -f "$MARKER" ) &
run 1 30
wait
check "docker restart issued" 1 "$(restarted)"
logged "logged the wait" "finished after"

echo "leaked marker: past the turn limit, restarts anyway"
clear_markers
echo '{"text":"hello","media":""}' > "$MARKER"
touch -t 202601010000 "$MARKER"   # POSIX -t: same syntax on GNU and BSD touch
run 1 2
check "docker restart issued" 1 "$(restarted)"
logged "logged the stale marker" "ignoring stale marker for Telegram turn"

echo "cron task in flight: skips the day, naming the task"
clear_markers
: > "$CRON_MARKER"
run 1 2
check "no docker restart" 0 "$(restarted)"
check "exit 0 (skip is not a failure)" 0 "$RC"
logged "logged the skip" "SKIPPING restart"
logged "named the cron task" "cron task 'daily-brief'"

echo "two markers, one clears in time: the other still blocks"
clear_markers
echo '{"text":"hello","media":""}' > "$MARKER"
: > "$CRON_MARKER"
( sleep 2; rm -f "$MARKER" ) &
run 1 4
wait
check "no docker restart" 0 "$(restarted)"
logged "logged the skip" "SKIPPING restart"
logged "still blocked by the cron task" "cron task 'daily-brief'"
case "$OUT" in
  *"SKIPPING"*"Telegram turn"*) echo "  FAIL cleared Telegram marker still blocking: $OUT"; fail=1 ;;
  *) echo "  ok the cleared Telegram marker stopped blocking" ;;
esac

echo "leaked cron lock: past the dispatch limit, restarts anyway"
clear_markers
: > "$CRON_MARKER"
touch -t 202601010000 "$CRON_MARKER"
run 1 2
check "docker restart issued" 1 "$(restarted)"
logged "logged the stale cron marker" "ignoring stale marker for cron task 'daily-brief'"

echo "two cron tasks in flight: both named in the skip"
clear_markers
: > "$CRON_MARKER"
: > "$CRON_MARKER2"
run 1 2
check "no docker restart" 0 "$(restarted)"
logged "named the first task" "cron task 'daily-brief'"
logged "named the second task" "cron task 'invoice-filer'"

echo "no state directory: fails loudly, restarts nothing"
rm -rf "${REPO}/state"
run 1 2
check "no docker restart" 0 "$(restarted)"
check "exit 1" 1 "$RC"
case "$OUT" in
  *"ERROR: no state directory"*) echo "  ok logged the misconfiguration" ;;
  *) echo "  FAIL error not logged: $OUT"; fail=1 ;;
esac

[ $fail -eq 0 ] && echo "restart_inflight: PASS" || { echo "restart_inflight: FAIL"; exit 1; }
