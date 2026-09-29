#!/usr/bin/env bash
set -uo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
LOGS_DIR="$WORK"; STATE_DIR="$WORK"; CLAUDE_BIN="claude"
fail() { echo "FAIL cron_respawn_marker: $*"; exit 1; }

source "${REPO_DIR}/watchers/plugins/claude_session.sh"
source "${REPO_DIR}/watchers/plugins/cron.sh"
BOT_CHANNEL_REPLIES_DIR="$WORK/replies"
mkdir -p "$BOT_CHANNEL_REPLIES_DIR"
log() { printf '%s\n' "$*" >> "$WORK/log"; }
log_failure() { printf '%s\n' "$1" >> "$WORK/failures"; }

marker="$WORK/.task.inflight"

echo 1 > "$STATE_DIR/.session-generation"
: > "$marker"
( sleep 1; echo 2 > "$STATE_DIR/.session-generation" ) &
_cron_wait_reply task req-respawn 30 "$marker" >/dev/null
wait
[ ! -e "$marker" ] || fail "in-flight marker kept after the session respawned, blocking re-dispatch"
grep -qx channel_respawn "$WORK/failures" || fail "respawn not recorded as channel_respawn"

: > "$marker"
_cron_wait_reply task req-timeout 1 "$marker" >/dev/null
[ -e "$marker" ] || fail "in-flight marker cleared on timeout while the run may still be executing"

echo PASS
