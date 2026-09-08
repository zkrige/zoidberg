#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/docker/sync-secret-store.sh"
if ! command -v sops >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "secret_store_decrypt: SKIP (needs sops and age-keygen)"
  exit 0
fi
fail() { echo "FAIL secret_store_decrypt: $1"; exit 1; }

WORK="$(mktemp -d)"
age-keygen -o "$WORK/key.txt" 2>/dev/null
PUB="$(grep -o 'age1[0-9a-z]*' "$WORK/key.txt")"
printf 'creation_rules:\n  - age: %s\n' "$PUB" > "$WORK/.sops.yaml"
cd "$WORK"
export SOPS_AGE_KEY_FILE="$WORK/key.txt"
export SECRET_STORE_SRC="$WORK/enc.json"
export SECRET_STORE_DEST="$WORK/home/config/credentials.json"
export SECRET_STORE_TASK_COPY="$WORK/store/credentials.json"
mkdir -p "$WORK/store"

printf '{"jira":{"api_token":"t1"},"bitbucket":{"api_token":"t2"}}' > "$WORK/plain.json"
sops encrypt "$WORK/plain.json" > "$SECRET_STORE_SRC"

out="$(bash "$SCRIPT")" || fail "decrypt run failed: $out"
printf '%s\n' "$out" | grep -q '2 entries' || fail "entry count not reported: $out"
[ "$(jq -r .bitbucket.api_token "$SECRET_STORE_DEST")" = t2 ] || fail "dest not decrypted"
[ "$(jq -r .bitbucket.api_token "$SECRET_STORE_TASK_COPY")" = t2 ] || fail "task copy not written"
[ "$(stat -f %Lp "$SECRET_STORE_DEST" 2>/dev/null || stat -c %a "$SECRET_STORE_DEST")" = 600 ] || fail "dest not mode 600"

printf '{"jira":{"api_token":"t3"}}' > "$WORK/plain.json"
sops encrypt "$WORK/plain.json" > "$SECRET_STORE_SRC"
bash "$SCRIPT" >/dev/null || fail "second run failed"
[ "$(jq -r .jira.api_token "$SECRET_STORE_TASK_COPY")" = t3 ] || fail "rotation not applied to task copy"

SOPS_AGE_KEY_FILE="$WORK/missing.txt" bash "$SCRIPT" >/dev/null 2>&1 && fail "undecryptable store did not abort"
[ "$(jq -r .jira.api_token "$SECRET_STORE_DEST")" = t3 ] || fail "failed decrypt clobbered the previous plaintext"

rm "$SECRET_STORE_SRC"
bash "$SCRIPT" >/dev/null || fail "absent store should be a no-op"

echo PASS
