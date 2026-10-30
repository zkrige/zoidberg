#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/git-failure.sh"
source "$(dirname "${BASH_SOURCE[0]}")/content-reload.sh"

AUTO_PUSH_LOCK="${AUTO_PUSH_LOCK:-/tmp/zoidberg-auto-push.lock}"
AUTO_PUSH_LOCK_WAIT=300

_auto_push_content_dir() {
  printf '%s' "${CONTENT_DIR:-/app/config}"
}

_auto_push_repo_name() {
  basename "$(git -C "$1" remote get-url origin)" .git
}

_auto_push_reload_for_prompts() {
  content_prompts_changed "$1" "$2" origin/main || return 0
  log "auto-push: content prompts changed, reloading via SIGHUP"
  kill -HUP "${SCHEDULER_PID:-1}"
}

_auto_push_rebase() {
  local repo_dir="$1" out base
  [ "$repo_dir" = "$(_auto_push_content_dir)" ] || return 0
  base=$(git -C "$repo_dir" merge-base HEAD origin/main)
  if out=$(git_remote -C "$repo_dir" pull --rebase origin main 2>&1); then
    _auto_push_reload_for_prompts "$repo_dir" "$base"
    return 0
  fi
  git -C "$repo_dir" rebase --abort 2>/dev/null
  notify "[auto-push] $(git_failure_message "$(_auto_push_repo_name "$repo_dir")" "git pull --rebase origin main" "$out")"
  return 1
}

_auto_push_push() {
  local repo_dir="$1" out
  if out=$(git_remote -C "$repo_dir" push origin main 2>&1); then
    return 0
  fi
  log "auto-push: $(_auto_push_repo_name "$repo_dir") push failed: $(git_first_error_line "$out")"
  return 1
}

_auto_push_repo() {
  local repo_dir="$1" summary
  [ -d "$repo_dir/.git" ] || return 1
  [ -n "$(git -C "$repo_dir" status --porcelain)" ] || return 1
  git -C "$repo_dir" add -A
  summary=$(git -C "$repo_dir" diff --cached --stat | tail -1)
  git -C "$repo_dir" commit -m "auto: bot update ($summary)" >/dev/null 2>&1 || return 1
  _auto_push_rebase "$repo_dir" || return 1
  _auto_push_push "$repo_dir" || return 1
  log "auto-push: pushed to $(_auto_push_repo_name "$repo_dir")"
}

_auto_push_all() {
  local repo_dir pushed=""
  for repo_dir in ${AUTO_PUSH_REPOS:-/app /home/claude/.claude/skills $(_auto_push_content_dir)}; do
    if _auto_push_repo "$repo_dir"; then
      pushed="${pushed:+${pushed}, }$(_auto_push_repo_name "$repo_dir")"
    fi
  done
  if [ -n "$pushed" ]; then
    notify "[auto-push] $pushed"
  fi
}

auto_push() {
  (
    flock -w "$AUTO_PUSH_LOCK_WAIT" 9 || exit 1
    _auto_push_all
  ) 9>"$AUTO_PUSH_LOCK"
}
