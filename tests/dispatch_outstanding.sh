#!/usr/bin/env bash
# Regression test for _claude_session_dispatch_outstanding.
#
# 2026-07-28: a dispatcher died mid-run and leaked .bitbucket-pr.inflight. cron.sh
# writes such a lock off past INFLIGHT_STALE and re-dispatches, but the context
# reset honoured any lock forever, so that one 0-byte file deferred every /clear
# for 16 hours while the session grew to 195k tokens against a 120k threshold.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
# Globals the plugin declares at source time (see its "Required globals" header).
LOGS_DIR="/tmp/dispatch-$$"; STATE_DIR="$LOGS_DIR"; CLAUDE_BIN="claude"
BUSY_LOCK="${STATE_DIR}/telegram.busy"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT
fail=0

tmux() { return 0; }
log() { :; }
# shellcheck source=watchers/plugins/claude_session.sh
source watchers/plugins/claude_session.sh

check() { # <label> <expected rc>
  set +e; _claude_session_dispatch_outstanding; local rc=$?; set -e
  if [ "$rc" = "$2" ]; then echo "  ok $1"; else echo "  FAIL $1: want rc=$2 got rc=$rc"; fail=1; fi
}

backdate() { touch -d '2 hours ago' "$1" 2>/dev/null || touch -A -020000 "$1"; }

echo "no locks"
check "nothing outstanding" 1

echo "fresh lock blocks the clear"
: > "${STATE_DIR}/.bitbucket-pr.inflight"
check "fresh lock is outstanding" 0

echo "lock older than INFLIGHT_STALE is abandoned"
backdate "${STATE_DIR}/.bitbucket-pr.inflight"
check "stale lock is not outstanding" 1

echo "a fresh lock among stale ones still blocks"
: > "${STATE_DIR}/.torrent-fix.inflight"
check "fresh lock wins" 0
rm -f "${STATE_DIR}"/.*.inflight

echo "busy locks are unaffected"
: > "$BUSY_LOCK"
check "telegram busy lock is outstanding" 0
rm -f "$BUSY_LOCK"
check "back to clear" 1

echo "agrees with cron.sh"
grep -q 'INFLIGHT_STALE:-1800' watchers/plugins/cron.sh \
  && grep -q 'INFLIGHT_STALE:-1800' watchers/plugins/claude_session.sh \
  && echo "  ok both use the same default" \
  || { echo "  FAIL INFLIGHT_STALE default differs between cron.sh and claude_session.sh"; fail=1; }

[ $fail -eq 0 ] && echo "dispatch_outstanding: PASS" || { echo "dispatch_outstanding: FAIL"; exit 1; }
