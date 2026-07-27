#!/bin/bash
# lib/setup-run.sh - the whole deterministic install sequence, in the one order
# that works.
#
# The ordering is not incidental and must not live in prose where it can be
# re-derived wrongly: Telegram has to stay off until Claude can actually
# answer, or the owner's first messages are dispatched to a session that
# cannot reply, hang, and get killed by the health probe. That looks like a
# broken install when it is only an unauthenticated one.
#
# Resumable: every phase checks whether it is already done, so re-running
# after a failure picks up where it stopped rather than starting over.
#
# Sourced by setup.sh, which owns CONTAINER, CONFIG, SECRETS, REPO_PATH,
# CONTENT_PATH, the output helpers, need_jq, require_files, json_write and ask.

_container_running() {
  docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

# _log_offset - lines already in automations.log, read from the host side of
# the bind mount so it also works before the container exists. A missing file
# is offset 0.
_log_offset() {
  local n
  n="$(wc -l < "${REPO_PATH}/logs/automations.log" 2>/dev/null | tr -d ' ')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# _wait_log <pattern> <timeout-seconds> <offset> ; polls, never a blind sleep.
#
# automations.log is append-only and only trimmed at 50k lines, so nothing
# truncates it on boot. Grepping the whole file matched a PREVIOUS boot's line
# in ~0s on every re-run and every container recreate, which meant this never
# actually waited for anything. Search only what was appended after the offset
# taken before the container was started.
_wait_log() {
  local pat="$1" limit="${2:-120}" from="${3:-0}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    docker exec "$CONTAINER" sh -c \
      "tail -n +$((from + 1)) /app/logs/automations.log 2>/dev/null | grep -q '$pat'" 2>/dev/null && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

_run_preflight() {
  head_ "Preflight"
  command -v docker >/dev/null 2>&1 || { err "docker not found. Run install.sh first."; exit 1; }
  ok "content overlay at ${CONTENT_PATH}"
  ok "framework at ${REPO_PATH}"

  # Before the container step: compose reads .env for its mount sources.
  cmd_env || exit 1

  # Telegram must not poll before Claude can answer. Safe to repeat.
  head_ "Holding Telegram until sign-in is done"
  json_write "$CONFIG" '.features.telegram = false' || exit 1
  ok "telegram disabled for now"
}

_run_telegram_creds() { # <token, possibly empty>
  head_ "Telegram credentials"
  local token="${1:-}" have_tok have_cid
  have_tok="$(jq -r '.telegram.bot_token // ""' "$SECRETS")"
  have_cid="$(jq -r '.telegram.chat_id // ""' "$SECRETS")"
  if [ -z "$token" ] && [ -n "$have_tok" ] && [ "$have_tok" != REPLACE_ME ] \
     && [ -n "$have_cid" ] && [ "$have_cid" != REPLACE_ME ]; then
    ok "already configured for chat ${have_cid}, leaving alone"
    return 0
  fi
  if [ -z "$token" ]; then
    info "Create a bot with @BotFather in Telegram (/newbot), then paste its token."
    ask 'Token: ' || {
      err "No terminal to read the token from, so nothing was entered."
      info "Pass it on the command line instead: setup.sh run <token>"
      exit 1
    }
    token="$ASK_REPLY"
  fi
  cmd_telegram "$token" || exit 1
}

_run_identity() {
  head_ "Git identity"
  local have_name; have_name="$(jq -r '.git.user_name // ""' "$CONFIG")"
  if [ -z "$have_name" ] || [ "$have_name" = "Your Name" ]; then
    cmd_identity || exit 1
  else
    ok "already set to ${have_name}, leaving alone"
  fi
}

# The owner was just told to message the bot, and would otherwise hear nothing
# at all until the build finishes.
_run_build_notice() {
  info "Building and starting. The first build pulls a lot: measured at about"
  info "four minutes on a laptop, longer on a small board. Later builds reuse"
  info "the cache and take seconds."
  _tg_send "Got your message, thanks.

Building the bot image now. That takes a few minutes, longer on a small board, and there is nothing for you to do here while it runs.

The installer will ask you to approve a sign-in URL in the terminal, and I will message you here once everything is running." \
    && ok "acknowledged you on Telegram so the wait is not silent"
}

_run_container() {
  head_ "Container"
  local log_from=0
  if _container_running; then
    ok "'${CONTAINER}' already running"
  else
    # Taken before the container starts, so the wait below cannot be satisfied
    # by a "daemon started" line from an earlier boot.
    log_from="$(_log_offset)"
    _run_build_notice
    ( cd "$REPO_PATH" && docker compose up -d --build ) || { err "docker compose failed"; exit 1; }
    _container_running || { err "container did not come up"; exit 1; }
    ok "container started"
  fi
  if _wait_log "daemon started" 180 "$log_from"; then ok "scheduler is up"
  else err "scheduler never reported 'daemon started'"; info "  check: docker logs ${CONTAINER}"; exit 1; fi
}

_run_signin() {
  head_ "Claude sign-in"
  if _claude_authed; then
    ok "already signed in, credential still valid"
    return 0
  fi
  cmd_login || exit 1
  printf '\n'
  ask 'Paste the code you were given (or press Enter to finish later): ' || {
    err "No terminal to read the sign-in code from, so nothing was entered."
    info "The sign-in is still open in the container. From a terminal, run:"
    info "  ${REPO_PATH}/setup.sh login <code>"
    info "then re-run: ${REPO_PATH}/setup.sh run"
    exit 1
  }
  if [ -z "$ASK_REPLY" ]; then
    warn "stopping here. Finish with: setup.sh login <code>, then re-run: setup.sh run"
    exit 0
  fi
  cmd_login "$ASK_REPLY" || exit 1
}

_run_enable_telegram() {
  head_ "Enabling Telegram"
  json_write "$CONFIG" '.features.telegram = true' || exit 1
  # Same append-only trap as _wait_log: without an offset a "daemon started"
  # line listing telegram from an earlier install passes this instantly.
  local hup_from; hup_from="$(_log_offset)"
  docker kill --signal=HUP "$CONTAINER" >/dev/null 2>&1
  ok "reload sent"
  local waited=0 line=""
  while [ "$waited" -lt 120 ]; do
    sleep 3; waited=$((waited + 3))
    line="$(docker exec "$CONTAINER" sh -c \
      "tail -n +$((hup_from + 1)) /app/logs/automations.log 2>/dev/null | grep 'daemon started' | tail -1" 2>/dev/null)"
    case "$line" in *telegram*) break ;; esac
  done
  case "$line" in
    *telegram*) ok "telegram plugin loaded" ;;
    *) err "telegram did not load after ${waited}s"; info "  check: docker exec ${CONTAINER} tail -30 /app/logs/automations.log"; exit 1 ;;
  esac
}

# Hand off through the bot rather than starting a second Claude on the host.
# The bot is the interface, its session already has the guardrails and the
# /setup skill (the session runs with cwd /app, so it picks up
# /app/.claude/skills), and going this way means the handoff also proves the
# thing actually works. "/setup" is neither a registered command nor a task
# name, so it falls through to Claude rather than being intercepted.
_run_handoff() {
  if _tg_send "Zoidberg is up and signed in.

Reply /setup and I will ask what you want automated, then write your schedule."; then
    info ""
    info "Check Telegram. Zoidberg has messaged you to finish setting up."
    info "Reply /setup there and it will ask what you want automated."
  else
    info ""
    warn "Could not message you on Telegram."
    info "Open the chat with your bot and send /setup to finish."
  fi
}

cmd_run() {
  need_jq; require_files
  _run_preflight
  _run_telegram_creds "${1:-}"
  _run_identity
  _run_container
  _run_signin
  _run_enable_telegram
  cmd_cron

  head_ "Verifying"
  cmd_verify --no-message || { err "setup finished but verification failed, see above"; exit 1; }

  head_ "Done"
  ok "Zoidberg is running."
  _run_handoff
}
