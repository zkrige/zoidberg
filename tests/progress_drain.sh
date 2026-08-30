#!/usr/bin/env bash
# progress_drain: the `progress` MCP tool writes sequenced
# <request_id>.progress.<seq> files that the Telegram stream loop drains and
# deletes while it waits for the reply. Guards the failure this replaced: the
# session used `reply` to acknowledge ("checking now, will confirm shortly"),
# which ENDS the request, so the promised follow-up was never sent and the
# owner had to ping again (2026-08-30).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOT_CHANNEL_REPLIES_DIR="/tmp/progressdrain-replies-$$"
mkdir -p "$BOT_CHANNEL_REPLIES_DIR"
trap 'rm -rf "$BOT_CHANNEL_REPLIES_DIR"' EXIT

# shellcheck source=/dev/null
source "${REPO_DIR}/lib/telegram-run.sh"

fail() { echo "FAIL progress_drain: $1"; exit 1; }

SENT="${BOT_CHANNEL_REPLIES_DIR}/sent.log"
DELETED="${BOT_CHANNEL_REPLIES_DIR}/deleted.log"
tg_send() { printf '%s\n' "$1" >> "$SENT"; }
tg_delete() { printf '%s\n' "$1" >> "$DELETED"; }
log() { :; }

request_id="tg-1-2"
_status_msg_id=""

write_progress() { printf '%s' "$2" > "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.progress.$1"; }

# 1. No progress files: nothing sent, no glob literal leaking through.
_telegram_run_drain_progress
[ ! -f "$SENT" ] || fail "sent something with no progress files"
[ -z "$(_telegram_progress_files "$BOT_CHANNEL_REPLIES_DIR" "$request_id")" ] \
  || fail "unglobbed pattern returned as a file"

# 2. Ordering is write order, not lexical-by-single-digit: 000010 after 000009.
write_progress 000009 "ninth"
write_progress 000010 "tenth"
write_progress 000002 "second"
_telegram_run_drain_progress
[ "$(cat "$SENT")" = "$(printf 'second\nninth\ntenth')" ] \
  || fail "wrong order: $(tr '\n' ',' < "$SENT")"

# 3. Drained files are deleted, so a second poll cannot resend them.
rm -f "$SENT"
_telegram_run_drain_progress
[ ! -f "$SENT" ] || fail "resent an already-drained update"

# 4. The reply file is not a progress file (suffix must not collide).
printf 'final answer' > "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt"
_telegram_run_drain_progress
[ ! -f "$SENT" ] || fail "drained the reply file as progress"
[ -f "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt" ] || fail "drain deleted the reply file"

# 5. Another request's updates are left alone.
printf 'not mine' > "${BOT_CHANNEL_REPLIES_DIR}/tg-9-9.progress.000001"
_telegram_run_drain_progress
[ ! -f "$SENT" ] || fail "drained another request's progress"
[ -f "${BOT_CHANNEL_REPLIES_DIR}/tg-9-9.progress.000001" ] || fail "deleted another request's progress"

# 6. The "working" status message is cleared once, before the first update, so
#    the update is the last thing on screen and the status line re-emits below.
_status_msg_id="555"
write_progress 000020 "one"
write_progress 000021 "two"
_telegram_run_drain_progress
[ "$(wc -l < "$DELETED" | tr -d ' ')" = "1" ] || fail "status message not deleted exactly once"
[ "$(cat "$DELETED")" = "555" ] || fail "deleted wrong status message id"
[ -z "$_status_msg_id" ] || fail "status msg id not cleared after delete"

# 7. An empty progress file is dropped, not sent as a blank Telegram message.
rm -f "$SENT" "$DELETED"
write_progress 000030 ""
_telegram_run_drain_progress
[ ! -f "$SENT" ] || fail "sent an empty progress update"
[ ! -f "${BOT_CHANNEL_REPLIES_DIR}/${request_id}.progress.000030" ] || fail "empty update not cleaned up"

echo "PASS progress_drain"
