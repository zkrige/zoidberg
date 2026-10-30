#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/git-failure.sh"
source "$(dirname "${BASH_SOURCE[0]}")/setup-telegram.sh"

sync_notify() {
  SECRETS="${CONTENT_PATH}/secrets.json" _tg_send "$1"
}

sync_repo_name() {
  basename "$(git remote get-url origin)" .git
}

sync_alert_file() {
  printf '%s/state/self-update-alert.%s' "$REPO_PATH" "$1"
}

sync_fail() {
  local label="$1" cmd="$2" out="$3" key hash alert_file
  key=$(sync_unresolved_state) || key="${cmd}|$(git_first_error_line "$out")"
  hash=$(printf '%s|%s' "$label" "$key" | cksum | cut -d' ' -f1)
  alert_file=$(sync_alert_file "$label")
  if [ "$(cat "$alert_file" 2>/dev/null)" != "$hash" ]; then
    if sync_notify "[self-update] $(git_failure_message "$label" "$cmd" "$out")"; then
      printf '%s\n' "$hash" > "$alert_file"
    fi
  fi
  return 1
}

sync_clear_alert() {
  local label="$1" alert_file
  alert_file=$(sync_alert_file "$label")
  [ -f "$alert_file" ] || return 0
  if sync_notify "[self-update] ${label} recovered"; then
    rm -f "$alert_file"
  fi
}

sync_step() {
  local label="$1" out
  shift
  if out=$("$@" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out"
  sync_fail "$label" "$*" "$out"
}

sync_unresolved_state() {
  local git_dir unmerged marker
  git_dir=$(git rev-parse --absolute-git-dir)
  unmerged=$(git diff --name-only --diff-filter=U | head -1)
  if [ -n "$unmerged" ]; then
    printf 'error: unmerged path %s' "$unmerged"
    return 0
  fi
  for marker in MERGE_HEAD rebase-merge rebase-apply; do
    if [ -e "$git_dir/$marker" ]; then
      printf 'error: %s present, merge or rebase unfinished' "$marker"
      return 0
    fi
  done
  return 1
}

sync_check_state() {
  local label="$1" state
  state=$(sync_unresolved_state) || return 0
  echo "[self-update] ${label}: ${state}"
  sync_fail "$label" "git status" "$state"
}

sync_pull() {
  local label="$1"
  if git diff --quiet && git diff --cached --quiet; then
    sync_step "$label" git pull --ff-only origin main
    return
  fi
  echo "[self-update] ${label}: stashing local changes"
  sync_step "$label" git stash || return 1
  sync_step "$label" git pull --ff-only origin main || return 1
  sync_step "$label" git stash pop
}

# shellcheck disable=SC2034
sync_repo() {
  local label
  label=$(sync_repo_name)
  SYNC_PULLED=0
  sync_check_state "$label" || return 1
  sync_step "$label" git fetch origin main --quiet || return 1
  SYNC_LOCAL=$(git rev-parse HEAD)
  SYNC_REMOTE=$(git rev-parse origin/main)
  if [ "$SYNC_LOCAL" != "$SYNC_REMOTE" ]; then
    echo "[self-update] ${label}: ${SYNC_LOCAL} -> ${SYNC_REMOTE}"
    sync_pull "$label" || return 1
    SYNC_PULLED=1
  fi
  sync_clear_alert "$label"
}
