#!/bin/bash
set -e

# Singleton: a rebuild takes far longer than the 5-minute cron interval, and
# the build marker is only written when the build FINISHES, so without this a
# tick landing mid-build would see "build files changed since last image
# build" and start a second concurrent docker build.
exec 9>"/tmp/zoidberg-self-update.lock"
flock -n 9 || exit 0

# Paths are derived, not hardcoded: setup.sh writes this script's real location
# into cron, so pinning /opt here silently broke the deploy loop for anyone who
# installed elsewhere. This script lives in scripts/, so the repo is its parent.
#
# resolve_host_paths also EXPORTS the three, which is the other half of the
# same bug: the compose rebuild below ran with none of the *_PATH names set, so
# a relocated install reverted to the built-in mounts on the next deploy.
REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../lib/paths.sh
source "${REPO_PATH}/lib/paths.sh"
resolve_host_paths

# chown to the container's uid is a Linux concern. On macOS the directories
# belong to the operator and Docker Desktop maps uids into the container, so
# doing it there would just take the files away from them.
maybe_chown() {
  [ "$(uname -s)" = "Linux" ] || return 0
  chown "$@" 2>/dev/null || true
}

# --- Automations repo (bind-mounted into container, code changes are live) ---
cd "$REPO_PATH"

# Mount points for the overlay bind mounts (/app/config, /app/skills). They live
# inside the repo directory but are not tracked, so a git operation or a fresh
# clone can leave them missing. Removing them under a running container breaks
# the nested mounts, so ensure they exist before any compose action below.
mkdir -p "$REPO_PATH/config" "$REPO_PATH/skills"
maybe_chown 1000:1000 "$REPO_PATH/config" "$REPO_PATH/skills"

git fetch origin main --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

# Seed the build marker BEFORE any pull: the running image matches the
# pre-pull commit, so a missing marker must not swallow build changes that
# arrive in this very run's pull (deploy_rebuild_needed's own bootstrap would
# set it to post-pull HEAD and skip that rebuild).
BUILD_MARKER="$REPO_PATH/state/.deployed-build-commit"
[ -f "$BUILD_MARKER" ] || printf '%s\n' "$LOCAL" > "$BUILD_MARKER"

PULLED=0
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
  PULLED=1
fi

# Rebuild when build files changed since the commit the running image was
# BUILT from (state/.deployed-build-commit), checked on EVERY run - not only
# when this script did the pulling. A commit born in the container's own tree
# (the bot edits the bind mount, commits, pushes) leaves HEAD == origin/main
# by the time this cron looks, so a pull-gated rebuild never fires
# (2026-08-13: a Dockerfile change sat unbuilt for an hour). A full recreate
# also reloads all scheduler code, so the SIGHUP branch below is rebuild's
# else-case.
if deploy_rebuild_needed "$REPO_PATH" "$BUILD_MARKER"; then
  echo "[self-update] build files changed since last image build, rebuilding container"
  docker compose up -d --build --force-recreate 2>&1
  deploy_mark_built "$REPO_PATH" "$BUILD_MARKER"
  # The build retags :latest onto the new image and leaves the previous one
  # untagged, so every Dockerfile change orphans a full image. At 2.27GB a
  # build that is not a rounding error: 34 of them had silently eaten 63GB
  # of the deploy host's disk before anyone looked. Dangling only, never -a,
  # which would also delete tagged images whose containers happen to be
  # stopped. Non-fatal: a prune failure must not fail an otherwise good
  # deploy, and set -e is in force.
  docker image prune -f 2>&1 || echo "[self-update] WARN: image prune failed"
elif [ "$PULLED" = 1 ]; then
  # Scheduler/plugin/lib code changed: the long-running scheduler is still
  # executing the old sourced functions, so send SIGHUP for an in-place
  # graceful reload (re-sources plugins + re-reads config). Pure
  # agents/scripts/docs changes are read fresh at dispatch and need no reload.
  CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE")
  if printf '%s\n' "$CHANGED" | grep -qE '^(watchers/|lib/.*\.sh|lib/channels/)'; then
    echo "[self-update] scheduler code changed, reloading via SIGHUP"
    docker kill --signal=HUP zoidberg 2>&1 || true
  else
    echo "[self-update] code-only change (no scheduler reload needed)"
  fi
fi

if [ "$PULLED" = 1 ]; then
  maybe_chown -R 1000:1000 "$REPO_PATH"
  echo "[self-update] $(date): automations update complete"
fi

# --- Skills repo (bind-mounted into container) ---
if [ -d "$SKILLS_PATH/.git" ]; then
  cd "$SKILLS_PATH"

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
    maybe_chown -R 1000:1000 "$SKILLS_PATH"
    echo "[self-update] $(date): skills sync complete"
  fi
fi

# --- Content repo (bind-mounted into container) ---
if [ -d "$CONTENT_PATH/.git" ]; then
  cd "$CONTENT_PATH"

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
    maybe_chown -R 1000:1000 "$CONTENT_PATH"
    echo "[self-update] $(date): content sync complete"
  fi
fi
