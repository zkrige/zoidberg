#!/bin/bash
# lib/setup-login.sh - Claude sign-in, without needing an interactive terminal
# on the server.
#
# `docker exec -it ... claude auth login` needs a TTY and a human at that
# terminal. Instead the login runs in a detached tmux pane inside the container,
# the OAuth URL is scraped out of the pane, and the code is typed back in. The
# URL can then be opened on any device. Nothing here needs a browser or a TTY
# on the host.
#
# The polling itself lives in lib/claude-login.sh, shared with the bot's
# Telegram /login handler so the two cannot drift apart again.
#
# Sourced by setup.sh, which owns CONTAINER, REPO_PATH and the output helpers.

# shellcheck source=SCRIPTDIR/claude-login.sh
source "${REPO_PATH}/lib/claude-login.sh"
dex() { docker exec -u claude "$CONTAINER" "$@"; }
CLAUDE_LOGIN_TMUX_PREFIX=(docker exec -u claude "$CONTAINER")

_cred_expiry() { # epoch ms of the current credential, 0 if none
  local e
  e="$(dex sh -c 'jq -r "(.claudeAiOauth.expiresAt // .expiresAt) // 0" /home/claude/.claude/.credentials.json 2>/dev/null' 2>/dev/null | tr -d '\r')"
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  printf '%s' "$e"
}

_claude_authed() {
  local e; e="$(_cred_expiry)"
  [ "$e" -gt 0 ] 2>/dev/null && [ "$(( e / 1000 ))" -gt "$(date +%s)" ]
}

_login_begin() {
  head_ "Starting Claude sign-in"
  local url
  url="$(claude_login_start)" || {
    err "No sign-in URL appeared after ${CLAUDE_LOGIN_URL_TIMEOUT}s."
    info "Run this again. If it keeps failing, check: docker logs ${CONTAINER}"
    exit 1
  }
  ok "sign-in URL ready"
  echo
  info "1. Open this on any device and approve:"
  echo
  printf '   %s\n' "$url"
  echo
  info "2. Copy the code it gives you, then run:"
  printf '   %ssetup.sh login <code>%s\n' "$C_B" "$C_0"
  echo
  info "The sign-in stays open in the container until you submit the code."
  info "Codes expire after a few minutes, so submit it while it is fresh."
}

_login_finish() { # <code>
  head_ "Submitting sign-in code"
  dex tmux has-session -t "$CLAUDE_LOGIN_SESSION" 2>/dev/null \
    || { err "No sign-in in progress. Run: setup.sh login"; exit 1; }
  if claude_login_submit "$1" _cred_expiry; then
    ok "signed in, credential renewed"
    dex tmux kill-session -t zoidberg 2>/dev/null
    ok "bot session restarted, it will come back in ~30s with fresh credentials"
    return 0
  fi
  err "Sign-in did not complete. ${CLAUDE_LOGIN_REASON}"
  info "Run 'setup.sh login' for a fresh URL and submit the new code."
  exit 1
}

cmd_login() {
  local code="${1:-}"
  docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER" \
    || { err "container '${CONTAINER}' is not running"; exit 1; }
  if [ -z "$code" ]; then _login_begin; else _login_finish "$code"; fi
}
