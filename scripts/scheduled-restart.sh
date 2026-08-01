#!/bin/bash
# Periodic restart of the bot container, run by host cron (not the bot itself,
# since the failure mode is a hung session).
#
# The restart is session hygiene, not context management: Claude Code's own
# auto-compaction bounds the session's context (see docs/ARCHITECTURE.md). This
# fully resets tmux, auth and session state as a periodic backstop. Runs daily.
set -e

# `docker`, not /usr/bin/docker: Docker Desktop installs it at
# /usr/local/bin/docker, so an absolute Linux path fails on a macOS host. The
# cron entry setup.sh writes pins a PATH that resolves it on both.
CONTAINER="${CONTAINER:-zoidberg}"

# docker-compose.yml bind-mounts the repo at /app and the scheduler puts
# STATE_DIR at ${REPO_DIR}/state, so the container's in-progress marker is
# readable straight off the host - no `docker exec` needed.
REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_PATH="${REPO_PATH}/state"
IN_PROGRESS_FILE="${STATE_PATH}/telegram-in-progress.json"

WAIT_INTERVAL="${RESTART_WAIT_INTERVAL:-10}"
# The longest a single dispatch can legitimately run: telegram.sh and cron.sh
# both cap a turn at CLAUDE_WALL_TIMEOUT (1200s).
WAIT_MAX="${RESTART_WAIT_MAX:-1200}"
# Past that wall timeout the owning code has removed its marker, so anything
# older leaked; honouring it would disable the restart permanently. 1800s is
# also cron.sh's own INFLIGHT_STALE, which frees a leaked .inflight lock.
STALE_AFTER="${RESTART_MARKER_STALE:-1800}"

# Set by wait_for_idle when it gives up, for the skip message.
BLOCKED_BY=""

say() { echo "[scheduled-restart] $(date): $*"; }

# BSD stat has no -c, GNU stat's -f means something else entirely.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

marker_label() {
  local base
  case "$1" in
    "$IN_PROGRESS_FILE") echo "Telegram turn" ;;
    *)
      base="$(basename "$1")"
      base="${base#.}"
      echo "cron task '${base%.inflight}'"
      ;;
  esac
}

# live_markers - one label per dispatch currently open, empty when idle.
# lib/telegram-run.sh writes telegram-in-progress.json before posting to the bot
# channel and removes it when the turn finalizes; cron.sh's _cron_post does the
# same with state/.<task>.inflight, one per concurrently dispatched task. An
# unmatched glob stays literal and drops out on the missing-mtime check.
live_markers() {
  local path mtime age label
  local paths=("$IN_PROGRESS_FILE" "${STATE_PATH}"/.*.inflight)
  for path in "${paths[@]}"; do
    # Also covers the file vanishing between two polls: no mtime, no dispatch.
    mtime="$(file_mtime "$path")" || continue
    age=$(( $(date +%s) - mtime ))
    label="$(marker_label "$path")"
    if [ "$age" -ge "$STALE_AFTER" ]; then
      # stdout here is the caller's label list, so the log goes to stderr.
      say "ignoring stale marker for ${label}: ${age}s old, past the ${STALE_AFTER}s dispatch limit" >&2
      continue
    fi
    echo "$label"
  done
}

# Command substitution drops the trailing newline, so no dangling separator.
one_line() { printf '%s' "$1" | tr '\n' ',' | sed 's/,/, /g'; }

wait_for_idle() {
  local waited=0 busy
  busy="$(live_markers)"
  [ -n "$busy" ] || return 0
  say "in flight, waiting up to ${WAIT_MAX}s: $(one_line "$busy")"
  while [ "$waited" -lt "$WAIT_MAX" ]; do
    sleep "$WAIT_INTERVAL"
    waited=$(( waited + WAIT_INTERVAL ))
    busy="$(live_markers)"
    [ -n "$busy" ] || { say "all dispatches finished after ${waited}s"; return 0; }
  done
  BLOCKED_BY="$busy"
  return 1
}

main() {
  if [ ! -d "$STATE_PATH" ]; then
    say "ERROR: no state directory at ${STATE_PATH} - cannot tell whether a dispatch is in flight"
    return 1
  fi

  if ! wait_for_idle; then
    # Skip rather than restart anyway. A restart on top of a live turn kills the
    # session mid-answer, and telegram_init's crash recovery then replays the raw
    # message into a brand-new session that has none of the context the message
    # assumed, producing a wrong answer. A killed cron dispatch leaves its
    # .inflight lock behind and loses the run's output. This restart is only
    # hygiene, so losing a day costs nothing; landing mid-turn costs a broken reply.
    say "SKIPPING restart: still in flight after ${WAIT_MAX}s: $(one_line "$BLOCKED_BY") (next daily run retries)"
    return 0
  fi

  say "restarting ${CONTAINER}"
  docker restart "$CONTAINER"
  say "done"
}

main
