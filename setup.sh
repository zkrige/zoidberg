#!/bin/bash
# setup.sh - Deterministic setup mechanism for Zoidberg.
#
# install.sh prepares the filesystem. This script does the mechanical parts of
# configuring the instance: validating a Telegram token, discovering the owner
# chat id, writing config, installing host cron, and verifying the result.
#
# It deliberately makes NO judgment calls. It never interviews the user, never
# invents a schedule, and never guesses what a failure means. Those belong to
# the /setup skill, which drives this script and interprets what it reports.
#
# Every subcommand is idempotent and safe to re-run.
#
# Usage:
#   ./setup.sh run [token]          the whole install sequence, resumable
#   ./setup.sh telegram <token>     validate token, store it, discover chat_id
#   ./setup.sh login                start Claude sign-in, print the URL
#   ./setup.sh login <code>         submit the sign-in code
#   ./setup.sh identity [name] [email]   write git identity (defaults to host git config)
#   ./setup.sh feature <name> <on|off>   enable or disable an optional feature
#   ./setup.sh cron                 install host cron entries
#   ./setup.sh env                  write .env with the host paths compose reads
#   ./setup.sh verify               check a running instance end to end
#   ./setup.sh status               report what is and is not configured
#
# run finishes by handing off to the bot on Telegram, where /setup writes
# your schedule.
#
# The subcommands themselves live in lib/setup-*.sh, sourced at the bottom.
# This file keeps only what all of them share: output helpers, path
# resolution, the JSON writer, the stdin reader, and the dispatch.

set -uo pipefail

CONTAINER="${CONTAINER:-zoidberg}"

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[error]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
info() { printf '%s\n' "$*"; }
head_() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

# Host paths. The repo is wherever this script is, never a literal: an install
# anywhere but /opt/zoidberg used to mean hand-editing this line. The overlay
# and skills come from the environment, then .env, then the sibling layout.
REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/paths.sh
source "${REPO_PATH}/lib/paths.sh"
resolve_host_paths || exit 1
SECRETS="${CONTENT_PATH}/secrets.json"
CONFIG="${CONTENT_PATH}/config.json"

need_jq() { command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }; }

# `setup.sh run` is also driven from a tool call by the /setup skill, where
# stdin is closed. A bare `read` gets EOF instantly there: the token prompt
# came back empty and the sign-in prompt silently "finished later" and exited
# 0, so the install reported done when nothing had been entered.
#
# Only the EOF case changes. stdin is still read first, so a terminal and a
# pipe both behave as before; a terminal is only reached for directly when
# stdin had nothing left to give, the way install.sh does when curl-piped.
#
# The open is probed in a subshell because with no controlling terminal (CI, a
# container without -t) /dev/tty exists and passes -r but opening it fails with
# ENXIO.
TTY_DEV=""
if (: < /dev/tty) 2>/dev/null; then
  TTY_DEV=/dev/tty
fi

ASK_REPLY=""
ask() { # <prompt> ; answer in ASK_REPLY, 1 when there is nobody left to ask
  ASK_REPLY=""
  printf '%s' "$1"
  read -r ASK_REPLY && return 0
  [ -n "$TTY_DEV" ] || return 1
  read -r ASK_REPLY < "$TTY_DEV"
}

# Write a JSON file atomically, validating before replacing the original. A
# broken secrets.json fails the container silently, so never leave one behind.
json_write() { # <file> [jq args...] <jq-filter>
  local file="$1"; shift
  # The temp file lands beside the original, so this needs the DIRECTORY
  # writable, not just the file. install.sh chowns the content overlay to
  # 1000:1000, which locks out any operator whose uid is neither that nor
  # root, and the redirect below would then blame jq for a permission error.
  local dir; dir="$(dirname "$file")"
  [ -w "$dir" ] || { err "${dir} is not writable by $(id -un) (uid $(id -u))"; return 1; }
  local tmp="${file}.tmp.$$"
  if ! jq "$@" > "$tmp" < "$file"; then err "jq failed writing ${file}"; rm -f "$tmp"; return 1; fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then err "refusing to write invalid JSON to ${file}"; rm -f "$tmp"; return 1; fi
  local mode; mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%A' "$file" 2>/dev/null || echo 600)"
  mv "$tmp" "$file"
  chmod "$mode" "$file"
}

require_files() {
  [ -f "$SECRETS" ] || { err "${SECRETS} not found. Run install.sh first."; exit 1; }
  [ -f "$CONFIG" ]  || { err "${CONFIG} not found. Run install.sh first."; exit 1; }
}

# shellcheck source=SCRIPTDIR/lib/setup-telegram.sh
source "${REPO_PATH}/lib/setup-telegram.sh"
# shellcheck source=SCRIPTDIR/lib/setup-config.sh
source "${REPO_PATH}/lib/setup-config.sh"
# shellcheck source=SCRIPTDIR/lib/setup-login.sh
source "${REPO_PATH}/lib/setup-login.sh"
# shellcheck source=SCRIPTDIR/lib/setup-cron.sh
source "${REPO_PATH}/lib/setup-cron.sh"
# shellcheck source=SCRIPTDIR/lib/setup-verify.sh
source "${REPO_PATH}/lib/setup-verify.sh"
# shellcheck source=SCRIPTDIR/lib/setup-run.sh
source "${REPO_PATH}/lib/setup-run.sh"

case "${1:-}" in
  run)      shift; cmd_run "$@" ;;
  telegram) shift; cmd_telegram "$@" ;;
  login)    shift; cmd_login "$@" ;;
  chatid)   shift; cmd_chatid "$@" ;;
  identity) shift; cmd_identity "$@" ;;
  env)      shift; cmd_env "$@" ;;
  feature)  shift; cmd_feature "$@" ;;
  cron)     shift; cmd_cron "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  -h|--help|"")
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) err "unknown subcommand: $1"; sed -n '18,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
