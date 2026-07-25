#!/bin/bash
# Periodic restart of the bot container, run by host cron (not the bot itself,
# since the failure mode is a hung session).
#
# The always-on interactive Claude session accumulates context from every
# dispatched task and persists across container restarts via the claude-home
# volume, so it grows over days/weeks. Eventually it crosses the 1M-token
# context tier, after which every dispatch fails with "Usage credits required
# for 1M context" and all automations silently stop. Restarting resets the
# session to empty context. Runs every 12h.
set -e

# `docker`, not /usr/bin/docker: Docker Desktop installs it at
# /usr/local/bin/docker, so an absolute Linux path fails on a macOS host. The
# cron entry setup.sh writes pins a PATH that resolves it on both.
CONTAINER="${CONTAINER:-zoidberg}"

echo "[scheduled-restart] $(date): restarting ${CONTAINER}"
docker restart "$CONTAINER"
echo "[scheduled-restart] $(date): done"
