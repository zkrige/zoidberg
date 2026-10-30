#!/bin/bash

# ---------------------------------------------------------------------------
# _claude_session_auth_expired - true if the session's LATEST turn failed with
# the expired-login error. Anthropic returns 401 with a 0 exit code and
# `claude auth status` still reports loggedIn, so the error itself is the only
# reliable signal.
#
# Read the transcript, not the pane. The pane is a rendering surface: it shows
# whatever the session is looking at, so grepping it for a phrase matched this
# very file whenever the bot opened claude_session.sh - which it does routinely,
# since it edits its own code. "Please run /login" appears four times in this
# repo. Same defect that pinned claude_session_is_busy busy forever on
# 2026-07-26; a false positive here alerts the owner that a healthy bot is down.
#
# The transcript records the failure structurally (isApiErrorMessage), which no
# rendered content can forge: source code the session reads arrives as a tool
# result, never as an assistant record carrying that flag. Only the newest
# assistant record counts - an older error the session has since recovered from
# must not read as currently expired.
# ---------------------------------------------------------------------------
CLAUDE_CREDENTIALS_FILE="${CLAUDE_CREDENTIALS_FILE:-${HOME}/.claude/.credentials.json}"

_claude_session_credentials_mtime() {
  date -r "$CLAUDE_CREDENTIALS_FILE" +%s 2>/dev/null || echo 0
}

_claude_session_auth_expired() {
  local f last
  f=$(ls -t "${CLAUDE_PROJECT_TRANSCRIPT_DIR}"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  last=$(tail -n 200 "$f" 2>/dev/null \
    | jq -rc --argjson since "$(_claude_session_credentials_mtime)" \
        'select(.type=="assistant")
         | if (.isApiErrorMessage==true)
              and ((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) >= $since)
           then ([.message.content[]? | .text // ""] | join(" "))
           else "" end' 2>/dev/null \
    | tail -1)
  case "$last" in *"Login expired"*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# claude_session_check_auth - alert the owner when the login has expired. The
# session can't re-login itself (interactive OAuth), so alert at most once an
# hour via Telegram with the re-login command. Reads the transcript, no API call.
# ---------------------------------------------------------------------------
_AUTH_CHECK_LAST=0
claude_session_check_auth() {
  local now; now=$(date +%s)
  [ $(( now - _AUTH_CHECK_LAST )) -ge 120 ] || return 0
  _AUTH_CHECK_LAST=$now
  local marker="${STATE_DIR}/.auth-failure-notified"
  if ! _claude_session_auth_expired; then
    rm -f "$marker"   # healthy: reset so the next failure alerts immediately
    return 0
  fi
  local last; last=$(cat "$marker" 2>/dev/null || echo 0)
  [ $(( now - last )) -ge 3600 ] || return 0
  echo "$now" > "$marker"
  log "claude-session: 401 auth-expired in transcript - alerting via Telegram"
  notify "⚠️ Claude auth expired - the bot is down (401 'Please run /login'). No tasks or replies will work until re-login.

Reply \`/login\` here and follow the two steps. No need to touch the server.
If Telegram itself is not working, fall back to \`./setup.sh login\` on the host."
}
