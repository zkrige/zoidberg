#!/usr/bin/env bash
# Health-probe spawn grace: the first probe after a spawn must wait a full
# probe interval. _HEALTH_PROBE_LAST starts at 0, so the first probe fired
# immediately after spawn, raced claude's startup (dialog accept, MCP
# handshake), timed out, and the +180s second probe landed strike 2: every
# daily 02:00 restart produced a false "wedged" respawn at 02:04
# (2026-08-02..08-13, 6/6 in production logs). Those false wedges were also
# the only "wedges" ever observed, which is why wedge respawns resume the
# conversation (--continue) instead of forcing a fresh session.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="/tmp/probegrace-$$"
mkdir -p "$WORK/state"
LOGS_DIR="$WORK"; STATE_DIR="$WORK/state"; CLAUDE_BIN="claude"; HOME="$WORK"
source "${REPO_DIR}/watchers/plugins/claude_session.sh"

fail() { echo "FAIL health_probe_grace: $1"; exit 1; }

# Stubs: no config values (empty, rc 0 - a failing stub inside $() would trip
# this script's set -e), idle session, record any probe post.
get_config() { echo ""; }
claude_session_is_busy() { return 1; }
log() { : ; }
POSTED="$WORK/posted"
bot_channel_post() { echo "$1" >> "$POSTED"; return 0; }
BUSY_LOCK="$WORK/no-such-lock"

# 1. Within the grace window (last probe "just happened"): no probe posted.
_HEALTH_PROBE_LAST=$(date +%s)
_HEALTH_PROBE_PENDING_RID=""
claude_session_health_probe
[ ! -f "$POSTED" ] || fail "probe posted inside grace window"

# 2. Interval elapsed: probe posts.
_HEALTH_PROBE_LAST=$(( $(date +%s) - 200 ))
claude_session_health_probe
[ -s "$POSTED" ] || fail "probe not posted after interval"

# 3. Spawn arms the grace: claude_session_spawn must set _HEALTH_PROBE_LAST.
grep -q '_HEALTH_PROBE_LAST=' <(type claude_session_spawn) || fail "spawn does not arm probe grace"

# 4. Wedge respawn must NOT force a fresh session (no observed wedge was
# content-caused; forcing fresh would wipe context on every false positive).
if grep -q 'session-fresh-spawn' <(type _claude_session_resolve_probe_failure); then
  fail "wedge respawn still forces fresh spawn"
fi

rm -rf "$WORK"
echo PASS
