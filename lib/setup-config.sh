#!/bin/bash
# lib/setup-config.sh - the subcommands that write or report the instance's
# own configuration: feature flags, git identity, .env, and status.
#
# Sourced by setup.sh, which owns CONTAINER, CONFIG, SECRETS, the output
# helpers, need_jq, require_files and json_write. env_write_defaults comes
# from lib/paths.sh.

cmd_feature() {
  need_jq; require_files
  local name="${1:-}" state="${2:-}"
  case "$state" in
    on|true)   state=true ;;
    off|false) state=false ;;
    "")        info "features: $(jq -c '.features // {}' "$CONFIG")"; return 0 ;;
    *) err "usage: setup.sh feature <name> <on|off>"; exit 1 ;;
  esac
  [ -n "$name" ] || { err "usage: setup.sh feature <name> <on|off>"; exit 1; }
  json_write "$CONFIG" --arg n "$name" --argjson v "$state" '.features[$n] = $v' || exit 1
  ok "feature ${name} set to ${state}"
  info "  reload to apply: docker kill --signal=HUP ${CONTAINER}"
}

# A freshly imaged host has no git identity, which is the normal case for the
# single-board computers this targets. Failing there aborted the whole install
# over a name used only to label commits the bot makes to the operator's own
# repos. Fall back to a placeholder and say how to change it, rather than
# stopping an install that is otherwise fine.
cmd_identity() {
  need_jq; require_files
  local name="${1:-$(git config --global user.name 2>/dev/null)}"
  local email="${2:-$(git config --global user.email 2>/dev/null)}"

  local placeholder=0
  if [ -z "$name" ] || [ -z "$email" ]; then
    name="${name:-Zoidberg}"
    email="${email:-zoidberg@localhost}"
    placeholder=1
  fi

  json_write "$CONFIG" --arg n "$name" --arg e "$email" \
    '.git.user_name = $n | .git.user_email = $e' || exit 1

  if [ "$placeholder" -eq 1 ]; then
    warn "no git identity on this host, using ${name} <${email}>"
    info "  it only labels commits the bot makes. Change it any time with:"
    info "    ./setup.sh identity \"Your Name\" you@example.com"
  else
    ok "git identity set to ${name} <${email}>"
  fi
}

# cmd_env - the .env that docker compose reads for its bind-mount sources. Run
# from here as well as install.sh so a hand clone and an install that predates
# the file both end up with one. Add-missing-keys-only, so re-running it never
# undoes a path you changed by hand.
cmd_env() {
  head_ "Host paths"
  env_write_defaults || return 1
  info "  compose reads this itself, so a relocated install needs no file edits"
}

STATUS_FAIL=0
_status_chk() { # <description> <ok|no>
  if [ "$2" = ok ]; then ok "$1"; else warn "$1"; STATUS_FAIL=1; fi
}

_status_secrets() {
  local t c mode
  t="$(jq -r '.telegram.bot_token // ""' "$SECRETS")"
  c="$(jq -r '.telegram.chat_id // ""' "$SECRETS")"
  [ -n "$t" ] && [ "$t" != "REPLACE_ME" ] && _status_chk "telegram bot_token set" ok \
    || _status_chk "telegram bot_token NOT set" no
  [ -n "$c" ] && [ "$c" != "REPLACE_ME" ] && _status_chk "telegram chat_id set" ok \
    || _status_chk "telegram chat_id NOT set" no
  mode="$(stat -c '%a' "$SECRETS" 2>/dev/null || stat -f '%A' "$SECRETS")"
  [ "$mode" = 600 ] && _status_chk "secrets.json mode 600" ok \
    || _status_chk "secrets.json mode ${mode}, expected 600" no
}

_status_config() {
  local n; n="$(jq -r '.git.user_name // ""' "$CONFIG")"
  [ -n "$n" ] && [ "$n" != "Your Name" ] && _status_chk "git identity set" ok \
    || _status_chk "git identity NOT set" no
  info "  features: $(jq -c '.features // {}' "$CONFIG")"
}

cmd_status() {
  need_jq
  head_ "Configuration"
  STATUS_FAIL=0
  [ -f "$SECRETS" ] && _status_chk "secrets.json present" ok || _status_chk "secrets.json missing" no
  [ -f "$CONFIG" ]  && _status_chk "config.json present" ok  || _status_chk "config.json missing" no
  [ -f "$SECRETS" ] && _status_secrets
  [ -f "$CONFIG" ] && _status_config
  return $STATUS_FAIL
}
