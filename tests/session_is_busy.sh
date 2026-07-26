#!/usr/bin/env bash
# Regression test for claude_session_is_busy pane scraping.
#
# 2026-07-26: the memory-prune turn rendered a state/memory.md diff into the
# pane, and that file's text quotes the phrase "esc to interrupt" (the note
# describing this very heuristic). The old whole-pane grep matched the quoted
# CONTENT and reported the session busy forever, starving the telegram
# idle-fallback so the dispatch hung for the full wall timeout.
#
# Both fixtures below are trimmed from real captured panes.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Globals the plugin declares at source time (see its "Required globals" header).
LOGS_DIR="/tmp/isbusy-$$"; STATE_DIR="$LOGS_DIR"; CLAUDE_BIN="claude"

# Stub tmux: `capture-pane` prints the fixture named by $FIXTURE, nothing else.
tmux() {
  case "${1:-}" in
    capture-pane) printf '%s\n' "$FIXTURE" ;;
    *) return 0 ;;
  esac
}

source "${REPO_DIR}/watchers/plugins/claude_session.sh"

# Idle, but conversation content quotes the busy phrase. Footer has no match.
IDLE_QUOTING_PHRASE='● Memory pruned - removed the stale entry.
      22  - claude_session_maybe_clear /clear-during-background-task bug: the
          pane footer read idle within 20s (no "esc to interrupt" between
          turns), so is_busy missed it and fired /clear.

--------------------------------------------------------------------------
> add it to radarr
--------------------------------------------------------------------------
  bypass permissions on (shift+tab to cycle) - for agents'

# Mid-turn. The footer itself carries the phrase.
BUSY='● Now writing the pruned version.

● Write(state/memory.md)

* Booping... (1m 33s)

--------------------------------------------------------------------------
>
--------------------------------------------------------------------------
  bypass permissions on (shift+tab to cycle) - esc to interrupt - for agents'

FIXTURE="$IDLE_QUOTING_PHRASE"
if claude_session_is_busy; then
  echo "FAIL idle-pane-quoting-phrase: reported busy while idle"; exit 1
fi

FIXTURE="$BUSY"
if ! claude_session_is_busy; then
  echo "FAIL busy-pane: reported idle while mid-turn"; exit 1
fi

echo PASS
