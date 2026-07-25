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
#   ./setup.sh verify               check a running instance end to end
#   ./setup.sh status               report what is and is not configured
#
# run finishes by handing off to the bot on Telegram, where /setup writes
# your schedule.

set -uo pipefail

CONTENT_DIR="${CONTENT_DIR:-/opt/zoidberg-config}"
REPO_DIR="${REPO_DIR:-/opt/zoidberg}"
CONTAINER="${CONTAINER:-zoidberg}"
SECRETS="${CONTENT_DIR}/secrets.json"
CONFIG="${CONTENT_DIR}/config.json"

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

need_jq() { command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }; }

# Write a JSON file atomically, validating before replacing the original. A
# broken secrets.json fails the container silently, so never leave one behind.
json_write() { # <file> <jq-filter> [jq args...]
  local file="$1"; shift
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

api() { # <token> <method>
  curl -sS --max-time 15 "https://api.telegram.org/bot${1}/${2}"
}

# Message the owner directly from the installer, not through the bot session
# (which does not exist yet for most of the run). Best effort: a failure here
# must never stop an install that is otherwise fine.
_tg_send() { # <text>
  local tok cid
  tok="$(jq -r '.telegram.bot_token // ""' "$SECRETS" 2>/dev/null)"
  cid="$(jq -r '.telegram.chat_id // ""' "$SECRETS" 2>/dev/null)"
  [ -n "$tok" ] && [ "$tok" != REPLACE_ME ] && [ -n "$cid" ] || return 1
  curl -sS --max-time 15 "https://api.telegram.org/bot${tok}/sendMessage" \
    -d chat_id="$cid" -d text="$1" | jq -e '.ok == true' >/dev/null 2>&1
}

cmd_telegram() {
  need_jq; require_files
  local token="${1:-}"
  [ -n "$token" ] || { err "usage: setup.sh telegram <token>"; exit 1; }

  head_ "Validating token"
  local me; me="$(api "$token" getMe)"
  if [ "$(printf '%s' "$me" | jq -r '.ok // false')" != "true" ]; then
    err "Telegram rejected that token."
    printf '%s\n' "$(printf '%s' "$me" | jq -r '.description // "no response from Telegram"')"
    info "Re-check the token from @BotFather and run this again."
    exit 1
  fi
  local uname; uname="$(printf '%s' "$me" | jq -r '.result.username')"
  ok "token valid, bot is @${uname}"

  json_write "$SECRETS" --arg tok "$token" '.telegram.bot_token = $tok' || exit 1
  chmod 600 "$SECRETS"
  ok "token stored in secrets.json (mode 600)"

  head_ "Discovering your chat id"
  info "Send any message to @${uname} in Telegram now (for example: hi)."
  local waited=0 interval=3 timeout="${CHATID_TIMEOUT:-180}" ids=""
  while [ "$waited" -lt "$timeout" ]; do
    ids="$(api "$token" getUpdates | jq -r '[.result[]?.message.chat.id] | unique | .[]' 2>/dev/null)"
    [ -n "$ids" ] && break
    sleep "$interval"; waited=$((waited + interval))
    [ $((waited % 15)) -eq 0 ] && info "  still waiting for a message... (${waited}s)"
  done

  if [ -z "$ids" ]; then
    err "No message seen after ${timeout}s."
    info "Note that a bot which has already been running will have consumed"
    info "older messages, so send a NEW one now, then re-run: setup.sh run"
    exit 1
  fi

  local count; count="$(printf '%s\n' "$ids" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    err "Saw more than one chat id, cannot choose for you:"
    printf '%s\n' "$ids" | sed 's/^/  /'
    info "Set the right one with: setup.sh chatid <id>"
    exit 1
  fi

  cmd_chatid "$ids"

  # Consume the updates discovery just read. getUpdates without an offset is
  # non-destructive, so without this the bot starts, polls, finds the "hi" the
  # owner only sent as a setup step, and answers it. That reply arrives in the
  # middle of the setup instructions and reads like the bot talking to itself.
  local last_id
  last_id="$(api "$token" getUpdates | jq -r '[.result[]?.update_id] | max // empty' 2>/dev/null)"
  if [ -n "$last_id" ]; then
    api "$token" "getUpdates?offset=$((last_id + 1))" >/dev/null 2>&1
    ok "cleared the setup messages so the bot does not reply to them"
  fi
}

cmd_chatid() {
  need_jq; require_files
  local cid="${1:-}"
  [ -n "$cid" ] || { err "usage: setup.sh chatid <id>"; exit 1; }
  json_write "$SECRETS" --arg cid "$cid" '.telegram.chat_id = $cid' || exit 1
  chmod 600 "$SECRETS"
  ok "chat_id ${cid} stored in secrets.json"
}

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

cmd_identity() {
  need_jq; require_files
  local name="${1:-$(git config --global user.name 2>/dev/null)}"
  local email="${2:-$(git config --global user.email 2>/dev/null)}"

  # A freshly imaged host has no git identity, which is the normal case for the
  # single-board computers this targets. Failing there aborted the whole install
  # over a name used only to label commits the bot makes to the operator's own
  # repos. Fall back to a placeholder and say how to change it, rather than
  # stopping an install that is otherwise fine.
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

# Claude sign-in, without needing an interactive terminal on the server.
#
# `docker exec -it ... claude auth login` needs a TTY and a human at that
# terminal. This mirrors what the bot already does for re-login over Telegram
# (see telegram_cmd_login_start in lib/telegram-commands.sh): run the login in
# a detached tmux pane inside the container, scrape the OAuth URL out of the
# pane, and take the resulting code back. The URL can then be opened on any
# device. Nothing here needs a browser or a TTY on the host.
LOGIN_TMUX="claude-login"
dex() { docker exec -u claude "$CONTAINER" "$@"; }

_cred_expiry() { # epoch ms of the current credential, 0 if none
  local e
  e="$(dex sh -c 'jq -r "(.claudeAiOauth.expiresAt // .expiresAt) // 0" /home/claude/.claude/.credentials.json 2>/dev/null' 2>/dev/null | tr -d '\r')"
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  printf '%s' "$e"
}

cmd_login() {
  local code="${1:-}"
  docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER" \
    || { err "container '${CONTAINER}' is not running"; exit 1; }

  if [ -z "$code" ]; then
    head_ "Starting Claude sign-in"
    dex tmux kill-session -t "$LOGIN_TMUX" 2>/dev/null
    dex tmux new-session -d -s "$LOGIN_TMUX" -x 1000 -y 50 || { err "could not start a tmux session"; exit 1; }
    dex tmux send-keys -t "$LOGIN_TMUX" "claude auth login --claudeai" Enter

    local url="" waited=0
    while [ "$waited" -lt 40 ]; do
      sleep 4; waited=$((waited + 4))
      url="$(dex tmux capture-pane -t "$LOGIN_TMUX" -p 2>/dev/null \
             | grep -oE 'https://claude\.com/cai/oauth/authorize[^ ]+' | head -1 | tr -d '\r')"
      [ -n "$url" ] && break
    done

    if [ -z "$url" ]; then
      dex tmux kill-session -t "$LOGIN_TMUX" 2>/dev/null
      err "No sign-in URL appeared after ${waited}s."
      info "Run this again. If it keeps failing, check: docker logs ${CONTAINER}"
      exit 1
    fi

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
    return 0
  fi

  head_ "Submitting sign-in code"
  dex tmux has-session -t "$LOGIN_TMUX" 2>/dev/null \
    || { err "No sign-in in progress. Run: setup.sh login"; exit 1; }

  local before after; before="$(_cred_expiry)"
  # -l sends literally; -- stops tmux reading a leading '-' as an option, which
  # would silently drop the code.
  dex tmux send-keys -t "$LOGIN_TMUX" -l -- "$code"
  dex tmux send-keys -t "$LOGIN_TMUX" Enter
  sleep 8
  after="$(_cred_expiry)"
  dex tmux kill-session -t "$LOGIN_TMUX" 2>/dev/null

  # A dead token can still report "logged in" with a future expiresAt, so the
  # only trustworthy signal is a credential that is both valid and newer.
  local now_s; now_s="$(date +%s)"
  if [ "$after" -gt 0 ] && [ "$(( after / 1000 ))" -gt "$(( now_s + 60 ))" ] && [ "$after" -gt "$before" ]; then
    ok "signed in, credential renewed"
    dex tmux kill-session -t zoidberg 2>/dev/null
    ok "bot session restarted, it will come back in ~30s with fresh credentials"
    return 0
  fi
  err "Sign-in did not complete (credential was not renewed)."
  info "Re-run 'setup.sh login', re-check the code, and submit it again."
  exit 1
}

# The whole deterministic install sequence, in the one order that works.
#
# The ordering is not incidental and must not live in prose where it can be
# re-derived wrongly: Telegram has to stay off until Claude can actually
# answer, or the owner's first messages are dispatched to a session that
# cannot reply, hang, and get killed by the health probe. That looks like a
# broken install when it is only an unauthenticated one.
#
# Resumable: every phase checks whether it is already done, so re-running
# after a failure picks up where it stopped rather than starting over.
_container_running() {
  docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

_wait_log() { # <pattern> <timeout-seconds> ; polls, never a blind sleep
  local pat="$1" limit="${2:-120}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    docker exec "$CONTAINER" sh -c "grep -q '$pat' /app/logs/automations.log" 2>/dev/null && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

_claude_authed() {
  local e; e="$(_cred_expiry)"
  [ "$e" -gt 0 ] 2>/dev/null && [ "$(( e / 1000 ))" -gt "$(date +%s)" ]
}

cmd_run() {
  need_jq; require_files
  local token="${1:-}"

  head_ "Preflight"
  command -v docker >/dev/null 2>&1 || { err "docker not found. Run install.sh first."; exit 1; }
  ok "content overlay at ${CONTENT_DIR}"
  ok "framework at ${REPO_DIR}"

  # Telegram must not poll before Claude can answer. Safe to repeat.
  head_ "Holding Telegram until sign-in is done"
  json_write "$CONFIG" '.features.telegram = false' || exit 1
  ok "telegram disabled for now"

  head_ "Telegram credentials"
  local have_tok have_cid
  have_tok="$(jq -r '.telegram.bot_token // ""' "$SECRETS")"
  have_cid="$(jq -r '.telegram.chat_id // ""' "$SECRETS")"
  if [ -n "$token" ] || [ -z "$have_tok" ] || [ "$have_tok" = REPLACE_ME ] \
     || [ -z "$have_cid" ] || [ "$have_cid" = REPLACE_ME ]; then
    if [ -z "$token" ]; then
      info "Create a bot with @BotFather in Telegram (/newbot), then paste its token."
      printf 'Token: '; read -r token
    fi
    cmd_telegram "$token" || exit 1
  else
    ok "already configured for chat ${have_cid}, leaving alone"
  fi

  head_ "Git identity"
  local have_name; have_name="$(jq -r '.git.user_name // ""' "$CONFIG")"
  if [ -z "$have_name" ] || [ "$have_name" = "Your Name" ]; then
    cmd_identity || exit 1
  else
    ok "already set to ${have_name}, leaving alone"
  fi

  head_ "Container"
  if _container_running; then
    ok "'${CONTAINER}' already running"
  else
    info "Building and starting. The first build pulls a lot: measured at about"
    info "four minutes on a laptop, longer on a small board. Later builds reuse"
    info "the cache and take seconds."
    # The owner was just told to message the bot, and would otherwise hear
    # nothing at all until the build finishes.
    _tg_send "Got your message, thanks.

Building the bot image now. That takes a few minutes, longer on a small board, and there is nothing for you to do here while it runs.

The installer will ask you to approve a sign-in URL in the terminal, and I will message you here once everything is running." \
      && ok "acknowledged you on Telegram so the wait is not silent"
    ( cd "$REPO_DIR" && docker compose up -d --build ) || { err "docker compose failed"; exit 1; }
    _container_running || { err "container did not come up"; exit 1; }
    ok "container started"
  fi
  if _wait_log "daemon started" 180; then ok "scheduler is up"
  else err "scheduler never reported 'daemon started'"; info "  check: docker logs ${CONTAINER}"; exit 1; fi

  head_ "Claude sign-in"
  if _claude_authed; then
    ok "already signed in, credential still valid"
  else
    cmd_login || exit 1
    printf '\nPaste the code you were given (or press Enter to finish later): '
    local code; read -r code
    if [ -z "$code" ]; then
      warn "stopping here. Finish with: setup.sh login <code>, then re-run: setup.sh run"
      exit 0
    fi
    cmd_login "$code" || exit 1
  fi

  head_ "Enabling Telegram"
  json_write "$CONFIG" '.features.telegram = true' || exit 1
  docker kill --signal=HUP "$CONTAINER" >/dev/null 2>&1
  ok "reload sent"
  local waited=0 line=""
  while [ "$waited" -lt 120 ]; do
    sleep 3; waited=$((waited + 3))
    line="$(docker exec "$CONTAINER" sh -c 'grep "daemon started" /app/logs/automations.log 2>/dev/null | tail -1' 2>/dev/null)"
    case "$line" in *telegram*) break ;; esac
  done
  case "$line" in
    *telegram*) ok "telegram plugin loaded" ;;
    *) err "telegram did not load after ${waited}s"; info "  check: docker exec ${CONTAINER} tail -30 /app/logs/automations.log"; exit 1 ;;
  esac

  cmd_cron

  head_ "Verifying"
  cmd_verify --no-message || { err "setup finished but verification failed, see above"; exit 1; }

  head_ "Done"
  ok "Zoidberg is running."

  # Hand off through the bot rather than starting a second Claude on the host.
  # The bot is the interface, its session already has the guardrails and the
  # /setup skill (the session runs with cwd /app, so it picks up
  # /app/.claude/skills), and going this way means the handoff also proves the
  # thing actually works. "/setup" is neither a registered command nor a task
  # name, so it falls through to Claude rather than being intercepted.
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

cmd_cron() {
  head_ "Host cron"
  # Without this the loop below prints "adding: ..." for each entry and then
  # dies on the crontab call, which reads like success right up to the error.
  if ! command -v crontab >/dev/null 2>&1; then
    err "crontab not found, so nothing can be scheduled."
    info "  The five-minute deploy and the daily restart both run from host cron."
    info "  Install it, then re-run this: sudo apt-get install -y cron"
    return 1
  fi
  local self="${REPO_DIR}/scripts/self-update.sh"
  local restart="${REPO_DIR}/scripts/scheduled-restart.sh"
  local added=0 current
  current="$(crontab -l 2>/dev/null)"

  # cron runs with a minimal PATH that does not include Docker Desktop's
  # /usr/local/bin symlinks on macOS, so both jobs would fail with
  # "docker: command not found" and the host would silently stop deploying.
  # Pin the PATH to whichever directory docker actually resolved to here.
  local docker_dir cron_path base_path
  docker_dir="$(dirname "$(command -v docker 2>/dev/null || echo /usr/bin/docker)")"
  base_path="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  case ":${base_path}:" in
    *":${docker_dir}:"*) cron_path="PATH=${base_path}" ;;
    *)                   cron_path="PATH=${docker_dir}:${base_path}" ;;
  esac

  # Logs go in the repo, not /var/log: on macOS cron runs as you and /var/log
  # is root-owned, so the redirect would fail and take the job with it.
  local logs="${REPO_DIR}/logs"
  mkdir -p "$logs" 2>/dev/null || true

  add_line() {
    if printf '%s\n' "$current" | grep -Fq "$2"; then
      ok "already present: $1"
    else
      current="$(printf '%s\n%s\n' "$current" "$2" | sed '/^$/d')"
      added=1
      ok "adding: $1"
    fi
  }

  if printf '%s\n' "$current" | grep -q '^PATH='; then
    ok "already present: cron PATH"
  else
    current="$(printf '%s\n%s\n' "$cron_path" "$current" | sed '/^$/d')"
    added=1
    ok "adding: cron PATH (${docker_dir})"
  fi

  [ -x "$self" ]    && add_line "self-update every 5 min"  "*/5 * * * * ${self} >> ${logs}/self-update.log 2>&1"
  [ -x "$restart" ] && add_line "daily container restart"  "0 4 * * * ${restart} >> ${logs}/scheduled-restart.log 2>&1"
  if [ "$added" -eq 1 ]; then
    printf '%s\n' "$current" | crontab - && ok "crontab updated"
  else
    ok "crontab already correct, nothing to do"
  fi
  crontab -l 2>/dev/null | grep -E "self-update|scheduled-restart" | sed 's/^/  /'
}

cmd_status() {
  need_jq
  head_ "Configuration"
  local fail=0
  chk() { if [ "$2" = ok ]; then ok "$1"; else warn "$1"; fail=1; fi; }
  [ -f "$SECRETS" ] && chk "secrets.json present" ok || chk "secrets.json missing" no
  [ -f "$CONFIG" ]  && chk "config.json present" ok  || chk "config.json missing" no
  if [ -f "$SECRETS" ]; then
    local t c; t="$(jq -r '.telegram.bot_token // ""' "$SECRETS")"; c="$(jq -r '.telegram.chat_id // ""' "$SECRETS")"
    [ -n "$t" ] && [ "$t" != "REPLACE_ME" ] && chk "telegram bot_token set" ok || chk "telegram bot_token NOT set" no
    [ -n "$c" ] && [ "$c" != "REPLACE_ME" ] && chk "telegram chat_id set" ok  || chk "telegram chat_id NOT set" no
    local mode; mode="$(stat -c '%a' "$SECRETS" 2>/dev/null || stat -f '%A' "$SECRETS")"
    [ "$mode" = 600 ] && chk "secrets.json mode 600" ok || chk "secrets.json mode ${mode}, expected 600" no
  fi
  if [ -f "$CONFIG" ]; then
    local n; n="$(jq -r '.git.user_name // ""' "$CONFIG")"
    [ -n "$n" ] && [ "$n" != "Your Name" ] && chk "git identity set" ok || chk "git identity NOT set" no
    info "  features: $(jq -c '.features // {}' "$CONFIG")"
  fi
  return $fail
}

cmd_verify() {
  need_jq
  local fail=0 quiet=0
  [ "${1:-}" = "--no-message" ] && quiet=1
  chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; fail=1; fi; }

  head_ "Container"
  chk "container '${CONTAINER}' is running" "docker ps --filter name=^${CONTAINER}$ --format '{{.Names}}' | grep -qx ${CONTAINER}"
  chk "scheduler is PID 1"                  "docker exec ${CONTAINER} sh -c 'ps -o comm= -p 1' | grep -q scheduler"
  chk "content overlay mounted"             "docker exec ${CONTAINER} test -f /app/config/schedule.json"
  chk "secrets readable in container"       "docker exec ${CONTAINER} test -r /app/config/secrets.json"
  chk "interactive session alive"           "docker exec ${CONTAINER} tmux has-session -t zoidberg"

  head_ "Claude authentication"
  if docker exec "$CONTAINER" sh -c 'grep -qi "not authenticated\|Please run /login" /app/logs/*.log 2>/dev/null'; then
    err "Claude CLI is NOT authenticated inside the container"
    info "  Fix it with: ./setup.sh login   (then: ./setup.sh login <code>)"
    fail=1
  else
    ok "no authentication errors in the logs"
  fi

  head_ "Plugins"
  # Both lines must come from the CURRENT boot. Grepping each independently
  # pairs a fresh "daemon started" with a stale "features disabled" from an
  # earlier run and reports day-old state as current. "features disabled" is
  # logged a few lines before "daemon started" in the same boot, so scope the
  # search to the tail of the log ending at the last "daemon started".
  local boot; boot="$(docker exec "$CONTAINER" sh -c '
    L=$(grep -n "daemon started" /app/logs/automations.log 2>/dev/null | tail -1 | cut -d: -f1)
    [ -n "$L" ] && sed -n "$((L>30 ? L-30 : 1)),${L}p" /app/logs/automations.log' 2>/dev/null)"
  local line; line="$(printf '%s\n' "$boot" | grep "daemon started" | tail -1)"
  if [ -n "$line" ]; then
    ok "${line#*] }"
    local dis; dis="$(printf '%s\n' "$boot" | grep "features disabled" | tail -1)"
    [ -n "$dis" ] && printf '  %s\n' "${dis#*] }"
  else
    err "scheduler never logged 'daemon started'"; fail=1
  fi

  # cmd_cron reported "adding: ..." for each entry and then died on a missing
  # crontab, and verification still passed, so the owner was told the install
  # was healthy while nothing would ever deploy. Check what is actually
  # scheduled, not what setup.sh believes it wrote.
  head_ "Host cron"
  if ! command -v crontab >/dev/null 2>&1; then
    err "crontab not installed - the deploy loop and daily restart cannot run"; fail=1
  else
    local ctab; ctab="$(crontab -l 2>/dev/null)"
    printf '%s\n' "$ctab" | grep -q "scripts/self-update.sh" \
      && ok "self-update scheduled" || { err "self-update NOT scheduled"; fail=1; }
    printf '%s\n' "$ctab" | grep -q "scripts/scheduled-restart.sh" \
      && ok "daily restart scheduled" || { err "daily restart NOT scheduled"; fail=1; }
  fi

  # `run` sends its own handoff message straight after this, which proves
  # outbound Telegram just as well. Sending a separate test message too means
  # the owner gets two near-identical bot messages to finish one install, so
  # run passes --no-message and lets the handoff be the proof.
  head_ "Telegram round trip"
  local tok cid
  tok="$(jq -r '.telegram.bot_token // ""' "$SECRETS" 2>/dev/null)"
  cid="$(jq -r '.telegram.chat_id // ""' "$SECRETS" 2>/dev/null)"
  if [ -z "$tok" ] || [ "$tok" = REPLACE_ME ] || [ -z "$cid" ]; then
    warn "telegram not configured, skipping round trip"
  elif [ "$quiet" = "1" ]; then
    ok "configured for chat ${cid} (handoff message follows)"
  else
    if curl -sS --max-time 15 "https://api.telegram.org/bot${tok}/sendMessage" \
        -d chat_id="$cid" -d text="Zoidberg check. If you can read this, outbound Telegram works." \
        | jq -e '.ok == true' >/dev/null 2>&1; then
      ok "sent a test message to chat ${cid}, check Telegram"
    else
      err "could not send a Telegram message"; fail=1
    fi
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    ok "verification passed"
  else
    err "verification found problems, see above"
  fi
  return $fail
}

case "${1:-}" in
  run)      shift; cmd_run "$@" ;;
  telegram) shift; cmd_telegram "$@" ;;
  login)    shift; cmd_login "$@" ;;
  chatid)   shift; cmd_chatid "$@" ;;
  identity) shift; cmd_identity "$@" ;;
  feature)  shift; cmd_feature "$@" ;;
  cron)     shift; cmd_cron "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  -h|--help|"")
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) err "unknown subcommand: $1"; sed -n '18,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
