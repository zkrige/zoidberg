#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
LOGS_DIR="$WORK"; STATE_DIR="$WORK"; CLAUDE_BIN="claude"
source "${REPO_DIR}/watchers/plugins/claude_session.sh"
log() { : ; }

KEYS="$WORK/keys"
tmux() {
  case "${1:-}" in
    capture-pane) [ -s "$KEYS" ] || echo "WARNING: Loading development channels" ;;
    send-keys) shift 3; echo "$*" >> "$KEYS" ;;
  esac
}

_claude_session_accept_dialog

[ "$(cat "$KEYS")" = "1" ] || { echo "FAIL accept_dialog: sent keys: $(tr '\n' ' ' < "$KEYS")"; exit 1; }
echo PASS
