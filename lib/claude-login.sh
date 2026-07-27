#!/bin/bash
# lib/claude-login.sh - Claude OAuth sign-in, shared by setup.sh and the
# Telegram /login handler.
#
# Both drive the same thing: `claude auth login --claudeai` in a detached tmux
# pane, the OAuth URL scraped out of that pane, the code typed back in. The one
# real difference is where tmux runs. setup.sh is on the host and reaches the
# pane through `docker exec`; the Telegram plugin is already inside the
# container. That prefix is the only injected variance.
#
# Everything here polls. Fixed sleeps were the original bug: an 8s sleep
# declares failure while the token exchange is still in flight, and the pane it
# then kills is the only place the exchange could have finished.

# `command` is a no-op prefix. Keeping this a one-element array rather than an
# empty one avoids `set -u` tripping on "${arr[@]}" under bash 3.2 (macOS).
CLAUDE_LOGIN_TMUX_PREFIX=(command)

CLAUDE_LOGIN_SESSION="claude-login"
CLAUDE_LOGIN_URL_TIMEOUT=90
CLAUDE_LOGIN_CODE_TIMEOUT=90
# The OAuth code expires server-side. The human-facing prompt is deliberately
# unbounded, so a code can easily be pasted long after it stopped being valid;
# past this age a non-renewal is far more likely to be an expired code than
# anything else worth reporting.
CLAUDE_LOGIN_CODE_TTL=300
# Terminal states of the login pane. Matching these ends the poll in ~2s with
# the right cause instead of burning the full ceiling and blaming a timeout.
CLAUDE_LOGIN_ERROR_RE='[Ii]nvalid code|[Cc]ode (has )?expired|[Ll]ogin failed|[Aa]uthentication failed|OAuth error'

# Reason the last claude_login_submit failed. Callers phrase the fix themselves.
CLAUDE_LOGIN_REASON=""

_claude_login_tmux() {
  "${CLAUDE_LOGIN_TMUX_PREFIX[@]}" tmux "$@"
}

_claude_login_pane() {
  _claude_login_tmux capture-pane -t "$CLAUDE_LOGIN_SESSION" -p 2>/dev/null
}

# _claude_login_started_at - epoch the URL was issued, 0 if unknown. Stored in
# the tmux session so it survives setup.sh running `login` and `login <code>`
# as two separate processes, and dies with the session.
_claude_login_started_at() {
  local v
  v="$(_claude_login_tmux show-environment -t "$CLAUDE_LOGIN_SESSION" \
       ZOIDBERG_LOGIN_AT 2>/dev/null | cut -d= -f2 | tr -d '\r')"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

# claude_login_start - launch the sign-in and print the OAuth URL on stdout.
# Returns 1 (and leaves no session behind) if no URL ever appeared.
claude_login_start() {
  _claude_login_tmux kill-session -t "$CLAUDE_LOGIN_SESSION" 2>/dev/null
  _claude_login_tmux new-session -d -s "$CLAUDE_LOGIN_SESSION" -x 1000 -y 50 || return 1
  _claude_login_tmux set-environment -t "$CLAUDE_LOGIN_SESSION" ZOIDBERG_LOGIN_AT "$(date +%s)"
  _claude_login_tmux send-keys -t "$CLAUDE_LOGIN_SESSION" "claude auth login --claudeai" Enter
  local waited=0 url=""
  while [ "$waited" -lt "$CLAUDE_LOGIN_URL_TIMEOUT" ]; do
    sleep 1; waited=$((waited + 1))
    url="$(_claude_login_pane | grep -oE 'https://claude\.com/cai/oauth/authorize[^ ]+' | head -1 | tr -d '\r')"
    if [ -n "$url" ]; then printf '%s' "$url"; return 0; fi
  done
  _claude_login_tmux kill-session -t "$CLAUDE_LOGIN_SESSION" 2>/dev/null
  return 1
}

# _claude_login_renewed <after-ms> <before-ms> - a credential that is both valid
# and newer. A dead token can still carry a future expiresAt (the
# 401-while-loggedIn case), so neither half alone is proof.
_claude_login_renewed() {
  local after="$1" before="$2" now_s
  now_s="$(date +%s)"
  [ "$after" -gt 0 ] 2>/dev/null || return 1
  [ "$(( after / 1000 ))" -gt "$(( now_s + 60 ))" ] && [ "$after" -gt "$before" ]
}

# _claude_login_poll <before-ms> <expiry-reader-fn>
# 0 renewed, 2 the pane reported a terminal error, 1 ran out of time.
_claude_login_poll() {
  local before="$1" reader="$2" waited=0 after
  while [ "$waited" -lt "$CLAUDE_LOGIN_CODE_TIMEOUT" ]; do
    sleep 2; waited=$((waited + 2))
    after="$("$reader")"
    _claude_login_renewed "$after" "$before" && return 0
    _claude_login_pane | grep -qE "$CLAUDE_LOGIN_ERROR_RE" && return 2
  done
  return 1
}

_claude_login_reason() { # <poll-status> <started-epoch>
  local status="$1" started="$2" age=0
  [ "$started" -gt 0 ] && age=$(( $(date +%s) - started ))
  if [ "$status" -eq 2 ]; then
    printf 'The sign-in screen rejected that code.'
  elif [ "$age" -gt "$CLAUDE_LOGIN_CODE_TTL" ]; then
    printf 'The code was issued %s minutes ago and has probably expired.' "$(( age / 60 ))"
  else
    printf 'The credential was not renewed within %ss.' "$CLAUDE_LOGIN_CODE_TIMEOUT"
  fi
}

# claude_login_submit <code> <expiry-reader-fn> - type the code in and wait for
# the credential to be rewritten. 0 signed in, 1 with CLAUDE_LOGIN_REASON set.
claude_login_submit() {
  local code="$1" reader="$2" before started status
  before="$("$reader")"
  started="$(_claude_login_started_at)"
  # -l sends the code literally; -- stops tmux reading a leading '-' as an
  # option, which would silently drop it.
  _claude_login_tmux send-keys -t "$CLAUDE_LOGIN_SESSION" -l -- "$code"
  _claude_login_tmux send-keys -t "$CLAUDE_LOGIN_SESSION" Enter
  _claude_login_poll "$before" "$reader"; status=$?
  if [ "$status" -eq 0 ]; then
    # Only on success. Killing the pane SIGHUPs claude, so killing it before
    # the verdict aborts the exchange it was about to declare failed and
    # leaves the retry with no session to talk to.
    _claude_login_tmux kill-session -t "$CLAUDE_LOGIN_SESSION" 2>/dev/null
    CLAUDE_LOGIN_REASON=""
    return 0
  fi
  CLAUDE_LOGIN_REASON="$(_claude_login_reason "$status" "$started")"
  return 1
}
