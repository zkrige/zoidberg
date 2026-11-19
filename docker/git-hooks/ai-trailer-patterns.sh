AI_TRAILER_REGEX='^Co-Authored-By:.*(Claude|anthropic)|^Claude-Session:|Generated with \[Claude'

chain_to_repo_hook() {
  local hook="$1" repo_hooks
  shift
  repo_hooks="$(git config --local core.hooksPath || true)"
  [ -n "$repo_hooks" ] || repo_hooks="$(git rev-parse --git-path hooks)"
  case "$repo_hooks" in /*) ;; *) repo_hooks="$(git rev-parse --show-toplevel)/${repo_hooks}" ;; esac
  [ "$repo_hooks" != "$(dirname "$0")" ] || return 0
  [ -x "${repo_hooks}/${hook}" ] || return 0
  "${repo_hooks}/${hook}" "$@"
}
