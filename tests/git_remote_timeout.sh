#!/usr/bin/env bash
# The scheduler runs autoupdate's fetch/pull/push and auto_push inside
# its one loop. On 2026-10-20 an ssh to github.com hung with no timeout and
# froze that loop for 1h42m: no Telegram polling, so /login never arrived while
# the session's OAuth had expired. git_remote must bound every remote call,
# ssh child included, for both plain and captured output.
# Run from repo root: bash tests/git_remote_timeout.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh

fail() { echo "FAIL git_remote_timeout: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git init -q "$WORK/repo"
git -C "$WORK/repo" remote add origin git@hang.invalid:x/y.git
export GIT_SSH_COMMAND='sleep 60 #'
GIT_REMOTE_TIMEOUT=2

start=$SECONDS rc=0
git_remote -C "$WORK/repo" fetch origin main >/dev/null 2>&1 || rc=$?
[ "$rc" = 124 ] || fail "fetch exit ${rc}, want 124 (timed out)"
[ $((SECONDS - start)) -le 10 ] || fail "fetch took $((SECONDS - start))s"

start=$SECONDS rc=0
out=$(git_remote -C "$WORK/repo" pull --rebase origin main 2>&1) || rc=$?
[ "$rc" = 124 ] || fail "pull exit ${rc}, want 124 (timed out): $out"
[ $((SECONDS - start)) -le 10 ] || fail "captured pull took $((SECONDS - start))s, ssh child outlived the timeout"

pgrep -f 'sleep 60' >/dev/null && fail "fake ssh child survived"
echo "ok git_remote_timeout"
