#!/usr/bin/env bash
# nudge_grace: the stream loop's idle-fallback must not fire while the session
# has said it is still working.
#
# 2026-08-30: the session dispatched a background Agent, called `progress`, and
# ended its turn to wait for the completion notification. The pane went idle,
# idle_streak hit 2 in ~4s, and the nudge forced a premature `reply`
# ("Compiling an updated status report - will send shortly") that CLOSED the
# request, so the agent's result reached nobody. Two guards:
#   - a `progress` call renews patience for PROGRESS_PATIENCE seconds
#   - after a nudge, wait NUDGE_GRACE before scraping the transcript
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOT_CHANNEL_REPLIES_DIR="/tmp/nudgegrace-$$"
mkdir -p "$BOT_CHANNEL_REPLIES_DIR"
trap 'rm -rf "$BOT_CHANNEL_REPLIES_DIR"' EXIT

fail() { echo "FAIL nudge_grace: $1"; exit 1; }

# This is the only time-based test in the suite: the loop under test advances on
# `sleep` and $SECONDS. Some sandboxed dev shells kill `sleep` outright, which
# stalls $SECONDS and spins the loop forever instead of failing. Assert the
# property the test needs, and skip rather than hang.
_t0=$SECONDS
sleep 1 2>/dev/null || true
if [ $(( SECONDS - _t0 )) -lt 1 ]; then
  echo "SKIP nudge_grace: sleep does not advance the clock in this shell"
  exit 0
fi

PLUGIN="${REPO_DIR}/watchers/plugins/telegram.sh"
for v in NUDGE_GRACE PROGRESS_PATIENCE; do
  grep -qE "^${v}=[0-9]+" "$PLUGIN" || fail "${v} not declared in watchers/plugins/telegram.sh"
done
NUDGE_GRACE=$(sed -n 's/^NUDGE_GRACE=\([0-9]*\).*/\1/p' "$PLUGIN")
PROGRESS_PATIENCE=$(sed -n 's/^PROGRESS_PATIENCE=\([0-9]*\).*/\1/p' "$PLUGIN")
# Both must beat the ~4s it takes idle_streak to reach 2, or they are no-ops.
[ "$NUDGE_GRACE" -gt 4 ] || fail "NUDGE_GRACE=${NUDGE_GRACE} does not outlast the idle window"
[ "$PROGRESS_PATIENCE" -gt 4 ] || fail "PROGRESS_PATIENCE=${PROGRESS_PATIENCE} does not outlast the idle window"

STREAM_INTERVAL=0.2
STATUS_INTERVAL=3600

# shellcheck source=/dev/null
source "${REPO_DIR}/lib/telegram-run.sh"

log() { :; }
tg_send() { :; }
tg_delete() { :; }
tg_send_get_id() { echo 1; }
tg_edit() { :; }
CLAUDE_TMUX_SESSION="zoidberg-test"
tmux() { :; }                                       # wall-timeout sends Escape
claude_session_is_busy() { return 1; }              # always idle: worst case
claude_session_last_assistant_uuid() { echo "new"; }
claude_session_last_assistant_text() { echo "Compiling a report, will send shortly."; }

request_id="tg-nudge-1"
reply_file="${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt"
NUDGES="${BOT_CHANNEL_REPLIES_DIR}/nudges.log"
bot_channel_post() { printf '%s\n' "$3" >> "$NUDGES"; }

reset() {
  rm -f "$reply_file" "$NUDGES" "${BOT_CHANNEL_REPLIES_DIR}/${request_id}".progress.*
  _status_msg_id=""; _baseline_uuid="base"; reply_salvaged=false; _last_progress_time=0
}

# 1. Silent turn-end, no progress: nudged at once, then held for NUDGE_GRACE
#    rather than salvaging the acknowledgement the nudge was sent to replace.
reset; CLAUDE_WALL_TIMEOUT=3
_telegram_run_stream
[ "$reply_salvaged" = false ] || fail "salvaged inside the nudge grace"
[ "$(wc -l < "$NUDGES" | tr -d ' ')" = "1" ] || fail "expected exactly one nudge"
grep -q 'Do NOT acknowledge or promise again' "$NUDGES" || fail "nudge still invites an acknowledgement"
grep -q 'background agent is still running' "$NUDGES" || fail "nudge does not cover the background-agent case"

# 2. A `progress` call means "still working": no nudge at all while it holds.
reset; CLAUDE_WALL_TIMEOUT=3
printf 'working on it' > "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.progress.000001"
_telegram_run_stream
[ ! -f "$NUDGES" ] || fail "nudged despite a fresh progress update"
[ "$reply_salvaged" = false ] || fail "salvaged despite a fresh progress update"

# 3. Patience is not permanent: once it lapses, the nudge fires again.
reset; CLAUDE_WALL_TIMEOUT=3; PROGRESS_PATIENCE=0
printf 'working on it' > "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.progress.000001"
_telegram_run_stream
[ -f "$NUDGES" ] || fail "never nudged after patience lapsed"
PROGRESS_PATIENCE=$(sed -n 's/^PROGRESS_PATIENCE=\([0-9]*\).*/\1/p' "$PLUGIN")

# 4. A reply landing during the nudge grace is used as-is, not overwritten.
reset; CLAUDE_WALL_TIMEOUT=3
bot_channel_post() { printf '%s\n' "$3" >> "$NUDGES"; printf 'real answer' > "$reply_file"; }
_telegram_run_stream
[ "$reply_salvaged" = false ] || fail "salvaged despite a reply arriving after the nudge"
[ "$(cat "$reply_file")" = "real answer" ] || fail "salvage overwrote the real reply"

# 5. The salvage fallback still works once both windows have elapsed.
reset; CLAUDE_WALL_TIMEOUT=10; NUDGE_GRACE=0
bot_channel_post() { printf '%s\n' "$3" >> "$NUDGES"; }
_telegram_run_stream
[ "$reply_salvaged" = true ] || fail "salvage never fired after the grace elapsed"
[ "$(cat "$reply_file")" = "Compiling a report, will send shortly." ] || fail "salvaged wrong text"

echo "PASS nudge_grace"
