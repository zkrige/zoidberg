#!/bin/bash
set -e

SRC="${SECRET_STORE_SRC:-/app/store/volume-backup/credentials.enc.json}"
DEST="${SECRET_STORE_DEST:-$HOME/.claude/config/credentials.json}"
TASK_COPY="${SECRET_STORE_TASK_COPY:-/app/store/credentials.json}"
[ -f "$SRC" ] || exit 0

if ! command -v sops >/dev/null; then
  echo "[secret-store] FATAL: sops not on PATH; cannot decrypt credentials" >&2
  exit 1
fi
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
if ! sops decrypt "$SRC" > "$tmp"; then
  rm "$tmp"
  echo "[secret-store] FATAL: sops decrypt failed. Check that" \
       "SOPS_AGE_KEY_FILE (${SOPS_AGE_KEY_FILE:-unset}) is readable by uid $(id -u)." >&2
  exit 1
fi
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp"; then
  rm "$tmp"
  echo "[secret-store] FATAL: decrypted credentials are not valid JSON" >&2
  exit 1
fi
chmod 600 "$tmp"
mv "$tmp" "$DEST"
cp "$DEST" "$TASK_COPY"
echo "[secret-store] synced credentials.json" \
     "($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$DEST") entries)"
