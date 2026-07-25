#!/usr/bin/env bash
# example-command.sh - minimal deterministic scheduled task.
#
# Runs as a schedule.json "command" entry: no Claude reasoning involved, the
# scheduler just executes this script directly. Use this pattern for
# no-reasoning, deterministic work (health checks, report generation, etc)
# instead of paying for a full agent dispatch.
#
# Config contract: read config.json via CONFIG_FILE if the caller set it,
# otherwise fall back to $CONTENT_DIR/config.json (the framework's default
# content overlay location, see lib/common.sh content_path()).
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-$CONTENT_DIR/config.json}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "example-command: config not found at $CONFIG_FILE" >&2
  exit 1
fi

git_user_email="$(jq -r '.git.user_email // "unknown"' "$CONFIG_FILE")"

echo "example-command: hello from the content overlay (git.user_email=${git_user_email})"
