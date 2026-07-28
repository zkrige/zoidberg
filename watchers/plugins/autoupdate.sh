#!/bin/bash
# watchers/plugins/autoupdate.sh - Periodic git pull to keep the repo up to date.
# Sourced by the orchestrator. Reads globals: REPO_DIR, LOGS_DIR.

_AUTOUPDATE_INTERVAL=300  # seconds between checks
_AUTOUPDATE_LAST=0

autoupdate_init() {
  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "autoupdate: WARNING - ${REPO_DIR} is not a git repo"
    return 1
  fi
  log "autoupdate: initialized (interval: ${_AUTOUPDATE_INTERVAL}s)"
  return 0
}

autoupdate_heal_perms() {
  # Host root SSH edits land as root-owned via the /opt/zoidberg
  # bind mount and break `git add` for the claude user. Heal before any
  # git op. The -quit makes the no-drift case a single dirent stat.
  local uid gid bad
  uid=$(id -u)
  gid=$(id -g)
  bad=$(find "$REPO_DIR" -not -user "$uid" -print -quit 2>/dev/null)
  if [ -n "$bad" ]; then
    sudo chown -R "${uid}:${gid}" "$REPO_DIR"
    log "autoupdate: healed ownership drift (first offender: ${bad})"
  fi
  bad=$(find "$REPO_DIR/.git/objects" -maxdepth 1 -type d ! -perm -755 -print -quit 2>/dev/null)
  if [ -n "$bad" ]; then
    find "$REPO_DIR/.git/objects" -maxdepth 1 -type d ! -perm -755 -exec chmod 755 {} +
    log "autoupdate: healed .git/objects perm drift (first offender: ${bad})"
  fi
}

# Classify a changed-file list the same way scripts/self-update.sh does. The
# two must agree: a file that means "rebuild" on the host cannot mean "reload"
# in here. Order matters, build wins over code.
_autoupdate_change_class() { # <newline-separated paths> -> build|code|content
  local changed="$1"
  if printf '%s\n' "$changed" | grep -qE '^(Dockerfile|docker/|docker-compose\.yml)'; then
    printf 'build'
  elif printf '%s\n' "$changed" | grep -qE '^(watchers/|lib/.*\.sh)'; then
    printf 'code'
  else
    printf 'content'
  fi
}

autoupdate_tick() {
  local now
  now=$(date +%s)
  if [ $(( now - _AUTOUPDATE_LAST )) -lt "$_AUTOUPDATE_INTERVAL" ]; then
    return
  fi
  _AUTOUPDATE_LAST=$now

  autoupdate_heal_perms

  # Cron tasks and submodule bumps dirty the tree without a Telegram message
  # to trigger auto-push, and a dirty tree makes pull --rebase fail and
  # hard-reset uncommitted work. Commit-and-push before pulling.
  # telegram_auto_push is defined by telegram.sh (all plugins are sourced
  # before any tick runs) and no-ops when the tree is clean.
  command -v telegram_auto_push >/dev/null 2>&1 && telegram_auto_push

  git -C "$REPO_DIR" fetch origin main >/dev/null 2>&1 || {
    log "autoupdate: git fetch failed"
    return
  }

  local ahead behind
  ahead=$(git -C "$REPO_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  behind=$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)

  if [ "$behind" = "0" ]; then
    return
  fi

  # scripts/self-update.sh decides rebuild vs reload by comparing HEAD to
  # origin/main. Pulling here makes those equal, so it finds nothing to do and
  # whatever this pull needed never happens: an image change is never built, a
  # scheduler change lands on disk while the running process keeps executing
  # the code it sourced at boot. Classify BEFORE pulling and act on it.
  local class
  class="$(_autoupdate_change_class "$(git -C "$REPO_DIR" diff --name-only HEAD origin/main 2>/dev/null)")"

  # A rebuild needs the docker CLI and the daemon socket. This container has
  # neither, so do not swallow the update: leave HEAD behind and let the host
  # deploy loop take it.
  if [ "$class" = build ]; then
    log "autoupdate: ${behind} commits change build files, leaving them to the host deploy loop"
    return
  fi

  local pull_output pull_exit
  pull_output=$(git -C "$REPO_DIR" pull --rebase origin main 2>&1)
  pull_exit=$?

  if [ $pull_exit -eq 0 ]; then
    log "autoupdate: updated (${behind} commits) - ${pull_output}"
    # PID 1 is the scheduler, which re-execs on SIGHUP and re-sources every
    # plugin. Same signal the host loop and /reload send.
    if [ "$class" = code ]; then
      log "autoupdate: scheduler code changed, reloading"
      kill -HUP 1
    fi
    # If auto-push raced a remote update its push was rejected; the commit
    # survived and was just rebased, so flush it now.
    if [ "$ahead" != "0" ]; then
      git -C "$REPO_DIR" push origin main 2>/dev/null \
        && log "autoupdate: pushed ${ahead} rebased local commits"
    fi
    return
  fi

  # Pull failed. If we have no un-pushed local commits, the failure is from
  # the remote being force-rewritten (or other diverging state we don't own).
  # Recover by hard-resetting to origin/main. If we DO have un-pushed local
  # commits, leave alone and notify so we don't lose work.
  if [ "$ahead" = "0" ]; then
    git -C "$REPO_DIR" reset --hard origin/main >/dev/null 2>&1
    log "autoupdate: rebase failed but no local commits, hard-reset to origin/main: ${pull_output}"
  else
    log "autoupdate: git pull failed with ${ahead} un-pushed local commits, NOT auto-resetting: ${pull_output}"
    notify "[autoupdate] pull failed with ${ahead} un-pushed commits - manual intervention needed"
  fi
}

autoupdate_cleanup() {
  : # no-op
}

autoupdate_on_wake() {
  _AUTOUPDATE_LAST=0  # force check on wake
}
