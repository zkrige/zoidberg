#!/bin/bash
# lib/setup-cron.sh - host cron entries for the five-minute deploy and the
# daily container restart.
#
# Sourced by setup.sh, which owns REPO_PATH and the output helpers.

CRON_TAB=""
CRON_ADDED=0

# Without this, cmd_cron prints "adding: ..." for each entry and then dies on
# the crontab call, which reads like success right up to the error.
_cron_require_crontab() {
  command -v crontab >/dev/null 2>&1 && return 0
  err "crontab not found, so nothing can be scheduled."
  info "  The five-minute deploy and the daily restart both run from host cron."
  info "  Install it, then re-run this: sudo apt-get install -y cron"
  return 1
}

_cron_add() { # <description> <crontab line>
  if printf '%s\n' "$CRON_TAB" | grep -Fq "$2"; then
    ok "already present: $1"
    return 0
  fi
  CRON_TAB="$(printf '%s\n%s\n' "$CRON_TAB" "$2" | sed '/^$/d')"
  CRON_ADDED=1
  ok "adding: $1"
}

# cron runs with a minimal PATH that does not include Docker Desktop's
# /usr/local/bin symlinks on macOS, so both jobs would fail with
# "docker: command not found" and the host would silently stop deploying.
# Pin the PATH to whichever directory docker actually resolved to here.
_cron_pin_path() {
  local docker_dir base_path cron_path
  docker_dir="$(dirname "$(command -v docker 2>/dev/null || echo /usr/bin/docker)")"
  base_path="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if printf '%s\n' "$CRON_TAB" | grep -q '^PATH='; then
    ok "already present: cron PATH"
    return 0
  fi
  case ":${base_path}:" in
    *":${docker_dir}:"*) cron_path="PATH=${base_path}" ;;
    *)                   cron_path="PATH=${docker_dir}:${base_path}" ;;
  esac
  CRON_TAB="$(printf '%s\n%s\n' "$cron_path" "$CRON_TAB" | sed '/^$/d')"
  CRON_ADDED=1
  ok "adding: cron PATH (${docker_dir})"
}

# Logs go in the repo, not /var/log: on macOS cron runs as you and /var/log is
# root-owned, so the redirect would fail and take the job with it.
cmd_cron() {
  head_ "Host cron"
  _cron_require_crontab || return 1
  local logs="${REPO_PATH}/logs"
  mkdir -p "$logs" 2>/dev/null || true
  local self="${REPO_PATH}/scripts/self-update.sh"
  local restart="${REPO_PATH}/scripts/scheduled-restart.sh"

  CRON_TAB="$(crontab -l 2>/dev/null)"
  CRON_ADDED=0
  _cron_pin_path
  [ -x "$self" ]    && _cron_add "self-update every 5 min"  "*/5 * * * * ${self} >> ${logs}/self-update.log 2>&1"
  [ -x "$restart" ] && _cron_add "daily container restart"  "0 4 * * * ${restart} >> ${logs}/scheduled-restart.log 2>&1"
  if [ "$CRON_ADDED" -eq 1 ]; then
    printf '%s\n' "$CRON_TAB" | crontab - && ok "crontab updated"
  else
    ok "crontab already correct, nothing to do"
  fi
  crontab -l 2>/dev/null | grep -E "self-update|scheduled-restart" | sed 's/^/  /'
}
