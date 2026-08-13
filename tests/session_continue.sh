#!/usr/bin/env bash
# _claude_session_continue_flag: respawns resume the previous conversation
# (--continue) so a deploy SIGHUP or daily container restart picks up where
# the session left off, EXCEPT when a fresh spawn was requested (wedge
# recovery writes state/.session-fresh-spawn - resuming a wedged conversation
# can resume the wedge) or when no prior conversation exists (--continue with
# nothing to continue errors at launch).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="/tmp/sesscont-$$"
mkdir -p "$WORK/state" "$WORK/transcripts"
# Globals the plugin declares at source time.
LOGS_DIR="$WORK"; STATE_DIR="$WORK/state"; CLAUDE_BIN="claude"; HOME="$WORK"
source "${REPO_DIR}/watchers/plugins/claude_session.sh"
CLAUDE_PROJECT_TRANSCRIPT_DIR="$WORK/transcripts"

fail() { echo "FAIL session_continue: $1"; exit 1; }

# 1. No prior conversation: no flag.
[ -z "$(_claude_session_continue_flag)" ] || fail "flag emitted with no transcripts"

# 2. Prior conversation exists: --continue.
touch "$WORK/transcripts/abc.jsonl"
[ "$(_claude_session_continue_flag)" = "--continue" ] || fail "no flag despite transcript"

# 3. Fresh-spawn marker: no flag, marker consumed.
touch "$STATE_DIR/.session-fresh-spawn"
[ -z "$(_claude_session_continue_flag)" ] || fail "flag emitted despite fresh marker"
[ ! -f "$STATE_DIR/.session-fresh-spawn" ] || fail "fresh marker not consumed"

# 4. Marker gone again: back to --continue.
[ "$(_claude_session_continue_flag)" = "--continue" ] || fail "flag not restored after marker consumed"

# 5. Wiring: the launch line uses the flag; wedge recovery requests fresh.
grep -q '_claude_session_continue_flag' <(type _claude_session_launch_tmux) || fail "launch not wired to continue flag"
grep -q 'session-fresh-spawn' <(type _claude_session_resolve_probe_failure) || fail "wedge respawn does not request fresh spawn"

rm -rf "$WORK"
echo PASS
