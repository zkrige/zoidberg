#!/bin/bash
set -e

# Paths are derived, not hardcoded: install.sh documents REPO_DIR/CONTENT_DIR/
# SKILLS_DIR as overridable, and setup.sh writes this script's real location
# into cron, so pinning /opt here silently broke the deploy loop for anyone who
# installed elsewhere. This script lives in scripts/, so the repo is its parent;
# the overlay and skills sit beside the repo unless overridden.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTENT_DIR="${CONTENT_DIR:-$(dirname "$REPO_DIR")/zoidberg-config}"
SKILLS_DIR="${SKILLS_DIR:-$(dirname "$REPO_DIR")/claude-skills}"

# chown to the container's uid is a Linux concern. On macOS the directories
# belong to the operator and Docker Desktop maps uids into the container, so
# doing it there would just take the files away from them.
maybe_chown() {
  [ "$(uname -s)" = "Linux" ] || return 0
  chown "$@" 2>/dev/null || true
}

# --- Automations repo (bind-mounted into container, code changes are live) ---
cd "$REPO_DIR"

# Mount points for the overlay bind mounts (/app/config, /app/skills). They live
# inside the repo directory but are not tracked, so a git operation or a fresh
# clone can leave them missing. Removing them under a running container breaks
# the nested mounts, so ensure they exist before any compose action below.
mkdir -p "$REPO_DIR/config" "$REPO_DIR/skills"
maybe_chown 1000:1000 "$REPO_DIR/config" "$REPO_DIR/skills"

git fetch origin main --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" != "$REMOTE" ]; then
  echo "[self-update] automations: $LOCAL -> $REMOTE"

  # Check for local uncommitted changes (bot may have edited files)
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[self-update] stashing local changes"
    git stash
    git pull --ff-only origin main
    git stash pop || echo "[self-update] WARN: stash pop conflict, changes in stash"
  else
    git pull --ff-only origin main
  fi

  # Rebuild container if Dockerfile or docker/ build files changed (full
  # recreate also reloads all scheduler code). Otherwise, if scheduler/plugin/
  # lib code changed, the long-running scheduler is still executing the old
  # sourced functions, so send SIGHUP for an in-place graceful reload
  # (re-sources plugins + re-reads config). Pure agents/scripts/docs changes
  # are read fresh at dispatch and need no reload.
  CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE")
  if printf '%s\n' "$CHANGED" | grep -qE '^(Dockerfile|docker/|docker-compose\.yml)'; then
    echo "[self-update] Dockerfile changed, rebuilding container"
    docker compose up -d --build --force-recreate 2>&1
  elif printf '%s\n' "$CHANGED" | grep -qE '^(watchers/|lib/.*\.sh)'; then
    echo "[self-update] scheduler code changed, reloading via SIGHUP"
    docker kill --signal=HUP zoidberg 2>&1 || true
  else
    echo "[self-update] code-only change (no scheduler reload needed)"
  fi

  maybe_chown -R 1000:1000 "$REPO_DIR"
  echo "[self-update] $(date): automations update complete"
fi

# --- Skills repo (bind-mounted into container) ---
if [ -d "$SKILLS_DIR/.git" ]; then
  cd "$SKILLS_DIR"

  git fetch origin main --quiet
  SKILLS_LOCAL=$(git rev-parse HEAD)
  SKILLS_REMOTE=$(git rev-parse origin/main)

  if [ "$SKILLS_LOCAL" != "$SKILLS_REMOTE" ]; then
    echo "[self-update] skills: $SKILLS_LOCAL -> $SKILLS_REMOTE"

    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "[self-update] stashing local skill changes"
      git stash
      git pull --ff-only origin main
      git stash pop || echo "[self-update] WARN: stash pop conflict, changes in stash"
    else
      git pull --ff-only origin main
    fi

    bash setup.sh
    maybe_chown -R 1000:1000 "$SKILLS_DIR"
    echo "[self-update] $(date): skills sync complete"
  fi
fi

# --- Content repo (bind-mounted into container) ---
if [ -d "$CONTENT_DIR/.git" ]; then
  cd "$CONTENT_DIR"

  git fetch origin main --quiet
  CONTENT_LOCAL=$(git rev-parse HEAD)
  CONTENT_REMOTE=$(git rev-parse origin/main)

  if [ "$CONTENT_LOCAL" != "$CONTENT_REMOTE" ]; then
    echo "[self-update] content: $CONTENT_LOCAL -> $CONTENT_REMOTE"

    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "[self-update] stashing local content changes"
      git stash
      git pull --ff-only origin main
      git stash pop || echo "[self-update] WARN: stash pop conflict, changes in stash"
    else
      git pull --ff-only origin main
    fi

    [ -f setup.sh ] && bash setup.sh
    maybe_chown -R 1000:1000 "$CONTENT_DIR"
    echo "[self-update] $(date): content sync complete"
  fi
fi
