#!/usr/bin/env bash
# Health probe stays on the standing model and effort unless config.json names
# its own. It used to default to haiku/low and switch with /model + /effort.
# CLI 2.1.30x opens a "Change effort level?" cache-miss confirm on /effort; the
# probe sat behind it, then the switch-back keystrokes ("/model sonnet" + Enter)
# landed in the picker: Enter accepted "switch to low" and the /model was lost.
# From 2026-10-18 14:47 UTC every Telegram turn ran on haiku.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="/tmp/probemodel-$$"
mkdir -p "$WORK/state"
trap 'rm -rf "$WORK"' EXIT
LOGS_DIR="$WORK"; STATE_DIR="$WORK/state"; CLAUDE_BIN="claude"; HOME="$WORK"
source "${REPO_DIR}/watchers/plugins/claude_session.sh"

fail() { echo "FAIL health_probe_model: $1"; exit 1; }

SENT="$WORK/sent"
touch "$SENT"
get_config() {
  case "$1" in
    .session.health_probe_model) echo "${PROBE_MODEL:-}" ;;
    .session.health_probe_effort) echo "${PROBE_EFFORT:-}" ;;
  esac
}
claude_session_is_busy() { return 1; }
log() { : ; }
sleep() { : ; }
flock() { return 0; }
tmux() { echo "$*" >> "$SENT"; }
bot_channel_post() { return 0; }
BUSY_LOCK="$WORK/no-such-lock"
echo sonnet > "$STATE_DIR/telegram-model.txt"
echo medium > "$STATE_DIR/telegram-effort.txt"

probe_once() {
  : > "$SENT"
  _HEALTH_PROBE_LAST=0
  _HEALTH_PROBE_PENDING_RID=""
  _HEALTH_PROBE_SWITCHED=0
  claude_session_health_probe
}

PROBE_MODEL=""; PROBE_EFFORT=""
probe_once
! grep -q -- '/model\|/effort' "$SENT" || fail "unconfigured probe switched the session: $(cat "$SENT")"

PROBE_MODEL=haiku; PROBE_EFFORT=low
probe_once
grep -q -- '/model haiku' "$SENT" || fail "configured probe model not applied"

echo PASS
