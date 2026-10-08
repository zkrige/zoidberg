#!/usr/bin/env bash
set -uo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
LOGS_DIR="$WORK"; STATE_DIR="$WORK"; CLAUDE_BIN="claude"
fail() { echo "FAIL cron_session_prepare: $*"; exit 1; }

source "${REPO_DIR}/watchers/plugins/claude_session.sh"
source "${REPO_DIR}/watchers/plugins/cron.sh"
log() { printf '%s\n' "$*" >> "$WORK/log"; }
BUSY_LOCK="$WORK/no-such-lock"
TURN="$WORK/turn-running"
EVENTS="$WORK/events"
claude_session_is_busy() { [ -e "$TURN" ]; }
claude_session_switch_model() { echo "switch $1 $2 busy=$([ -e "$TURN" ] && echo 1 || echo 0)" >> "$EVENTS"; }

: > "$TURN"
( sleep 2; rm "$TURN" ) &
exec 9>"$MODEL_SWITCH_LOCK"
_cron_prepare_session task sonnet medium haiku low
wait
[ "$(cat "$EVENTS")" = "switch sonnet medium busy=0" ] || fail "switch sent into a running turn: $(cat "$EVENTS")"

: > "$EVENTS"
: > "$TURN"
( sleep 2; rm "$TURN" ) &
_cron_restore_session sonnet medium haiku low
wait
[ "$(cat "$EVENTS")" = "switch haiku low busy=0" ] || fail "switch-back sent into a running turn: $(cat "$EVENTS")"

: > "$EVENTS"
exec 9>"$MODEL_SWITCH_LOCK"
_cron_prepare_session task sonnet medium sonnet medium
[ ! -s "$EVENTS" ] || fail "switched although the task model is the standing default"
[ "$_CRON_SWITCHED" -eq 0 ] || fail "marked switched without switching"
exec 9>&-

echo PASS
