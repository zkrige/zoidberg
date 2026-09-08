#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_DIR}/lib/paths.sh"

fail() { echo "FAIL secret_store_sync: $1"; exit 1; }
gitc() { git -c user.name=t -c user.email=t@t "$@"; }

WORK="$(mktemp -d)"
FILE="config/credentials.enc.json"
gitc init -q --bare "$WORK/origin.git"
gitc clone -q "$WORK/origin.git" "$WORK/author" 2>/dev/null
mkdir -p "$WORK/author/config"
echo ciphertext-v1 > "$WORK/author/$FILE"
echo unrelated > "$WORK/author/README.md"
gitc -C "$WORK/author" add -A
gitc -C "$WORK/author" commit -q -m v1
gitc -C "$WORK/author" push -q origin HEAD

MIRROR="$WORK/mirror"
DEST="$WORK/store/credentials.enc.json"
mkdir -p "$WORK/store"

secret_store_mirror "$WORK/origin.git" "$FILE" "$MIRROR" || fail "initial mirror failed"
[ "$(cat "$MIRROR/$FILE")" = ciphertext-v1 ] || fail "mirror did not check out the ciphertext"
[ -e "$MIRROR/README.md" ] && fail "mirror checked out files outside the sparse set"

secret_store_changed "$MIRROR/$FILE" "$DEST" || fail "missing dest not reported as changed"
cp "$MIRROR/$FILE" "$DEST"
secret_store_changed "$MIRROR/$FILE" "$DEST" && fail "identical dest reported as changed"

echo ciphertext-v2 > "$WORK/author/$FILE"
gitc -C "$WORK/author" commit -q -am v2
gitc -C "$WORK/author" push -q origin HEAD
secret_store_mirror "$WORK/origin.git" "$FILE" "$MIRROR" || fail "second mirror failed"
[ "$(cat "$MIRROR/$FILE")" = ciphertext-v2 ] || fail "mirror did not pick up the new ciphertext"
secret_store_changed "$MIRROR/$FILE" "$DEST" || fail "new ciphertext not reported as changed"

secret_store_changed "$WORK/nowhere" "$DEST" && fail "missing source reported as changed"

secret_store_mirror "$WORK/origin.git" "missing.json" "$WORK/mirror2" && fail "mirror of a missing file succeeded"

SU="${REPO_DIR}/scripts/self-update.sh"
grep -q 'secret_store_mirror' "$SU" || fail "self-update.sh not wired to secret_store_mirror"
grep -q 'secret_store_changed' "$SU" || fail "self-update.sh not wired to secret_store_changed"
grep -q 'docker exec zoidberg bash /app/docker/sync-secret-store.sh' "$SU" || fail "self-update.sh does not re-decrypt inside the container"
grep -q 'bash /app/docker/sync-secret-store.sh' "${REPO_DIR}/docker/entrypoint.sh" || fail "entrypoint does not run the shared decrypt script"
git -C "$REPO_DIR" check-ignore -q docker/sync-secret-store.sh && fail "docker/sync-secret-store.sh is gitignored"
git -C "$REPO_DIR" check-ignore -q tests/secret_store_sync.sh && fail "this test is gitignored"
bash -n "${REPO_DIR}/docker/sync-secret-store.sh" || fail "sync-secret-store.sh does not parse"
bash -n "$SU" || fail "self-update.sh does not parse"
bash -n "${REPO_DIR}/docker/entrypoint.sh" || fail "entrypoint.sh does not parse"

echo PASS
