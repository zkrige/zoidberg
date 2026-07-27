#!/usr/bin/env bash
# docker-compose.yml resolves every repo bind mount to the paths lib/paths.sh
# derived, for a repo that is not at /opt/zoidberg, and is byte-identical to
# the old literals at the canonical layout.
# Run from repo root: bash tests/compose_paths.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v docker >/dev/null 2>&1; then
  echo "compose_paths: SKIP (no docker on this host)"
  exit 0
fi
PATHS_LIB="$(pwd)/lib/paths.sh"
COMPOSE_YML="$(pwd)/docker-compose.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# A repo somewhere other than /opt/zoidberg, set up the way setup.sh env does:
# resolve the paths, then write them to the .env compose reads for itself.
RELOC="${TMP}/somewhere/zoidberg"
mkdir -p "$RELOC"
cp "$COMPOSE_YML" "$RELOC/"
env -i PATH="$PATH" HOME="$HOME" REPO_PATH="$RELOC" bash -c '
  source "$0"
  resolve_host_paths && env_write_defaults' "$PATHS_LIB" >/dev/null

# mounts <dir> [KEY=VALUE...] - "target<TAB>source" for every bind mount
mounts() {
  local dir="$1"; shift
  ( cd "$dir" && env "$@" docker compose config --format json ) \
    | jq -r '.services.zoidberg.volumes[] | select(.type == "bind") | "\(.target)\t\(.source)"'
}

check_mount() { # <label> <mounts> <target> <expected source>
  local got
  got="$(printf '%s\n' "$2" | awk -F'\t' -v t="$3" '$1 == t { print $2 }')"
  if [ "$got" = "$4" ]; then echo "ok   $1 ${3} <- ${4}"
  else echo "FAIL $1 ${3} is [${got}], want [${4}]"; fail=1; fi
}

check_layout() { # <label> <mounts> <repo> <content> <skills>
  check_mount "$1" "$2" /app "$3"
  check_mount "$1" "$2" /app/config "$4"
  check_mount "$1" "$2" /app/skills "$5"
  check_mount "$1" "$2" /home/claude/.claude/skills "$5"
}

relocated="$(mounts "$RELOC")"
check_layout relocated "$relocated" \
  "$RELOC" "${TMP}/somewhere/zoidberg-config" "${TMP}/somewhere/claude-skills"

# The canonical layout is the same compose file with the /opt paths in the
# environment, which compose takes over the .env. These are the literals the
# mounts were hardcoded to before they were derived, so nothing may move.
canonical="$(mounts "$RELOC" \
  REPO_PATH=/opt/zoidberg CONTENT_PATH=/opt/zoidberg-config SKILLS_PATH=/opt/claude-skills)"
check_layout canonical "$canonical" \
  /opt/zoidberg /opt/zoidberg-config /opt/claude-skills

[ $fail -eq 0 ] && echo "compose_paths: PASS" || { echo "compose_paths: FAIL"; exit 1; }
