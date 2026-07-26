#!/usr/bin/env bash
# The session scrapes are self-matching hazards: the bot edits its own code, so
# claude_session.sh's text lands on the pane it greps. Written literally, a
# pattern matches the line that defines it. 2026-07-26 that took the bot down
# via claude_session_is_busy; these are the same class.
#
# Fixture for the negative cases is the real claude_session.sh, so the assertion
# is literally "rendering this file must not trigger its own checks".
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOGS_DIR="/tmp/selfmatch-$$"; STATE_DIR="$LOGS_DIR"; CLAUDE_BIN="claude"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT

SENT_KEYS=""
tmux() {
  case "${1:-}" in
    capture-pane) printf '%s\n' "$FIXTURE" ;;
    send-keys)    SENT_KEYS="${SENT_KEYS}$* " ;;
    *) return 0 ;;
  esac
}
log() { :; }
notify() { :; }

source "${REPO_DIR}/watchers/plugins/claude_session.sh"

PLUGIN_SOURCE=$(cat "${REPO_DIR}/watchers/plugins/claude_session.sh")

# --- picker check: must not fire on this file's own source ------------------
FIXTURE="$PLUGIN_SOURCE"
SENT_KEYS=""
_claude_session_release_interactive_prompt
if [ -n "$SENT_KEYS" ]; then
  echo "FAIL picker-self-match: sent '$SENT_KEYS' while rendering own source"; exit 1
fi

# --- picker check: must still fire on a real picker --------------------------
FIXTURE='Do you want to proceed?
  1. Yes
  2. No

Enter to select · Esc to cancel'
SENT_KEYS=""
_claude_session_release_interactive_prompt
case "$SENT_KEYS" in
  *Escape*) : ;;
  *) echo "FAIL picker-real: no Escape sent for a live picker"; exit 1 ;;
esac

# --- auth check reads the transcript, so the pane cannot forge it ------------
CLAUDE_PROJECT_TRANSCRIPT_DIR="${STATE_DIR}/transcripts"
mkdir -p "$CLAUDE_PROJECT_TRANSCRIPT_DIR"
T="${CLAUDE_PROJECT_TRANSCRIPT_DIR}/live.jsonl"

# Healthy: newest assistant record is an ordinary reply. The session having READ
# its own source (a tool result quoting "Please run /login") must not count.
{
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Login expired · Please run /login"}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"grep -qiE \"Invalid authentication credentials|Please run /login\""}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Re-logged in, all good."}]}}'
} > "$T"
if _claude_session_auth_expired; then
  echo "FAIL auth-recovered: reported expired after the session recovered"; exit 1
fi

# Expired: newest assistant record IS the api error.
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Login expired · Please run /login"}]}}' >> "$T"
if ! _claude_session_auth_expired; then
  echo "FAIL auth-expired: missed a live expired-login error"; exit 1
fi

# --- invariant: no pane-grepped literal may appear in the plugin source ------
# Guards against a future edit reintroducing a literal pattern.
for lit in 'Enter to select' 'Esc to cancel'; do
  if printf '%s' "$PLUGIN_SOURCE" | grep -q "$lit"; then
    echo "FAIL literal-reintroduced: '$lit' is present in claude_session.sh"; exit 1
  fi
done

echo PASS
