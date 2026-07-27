#!/bin/bash
# lib/setup-verify.sh - end-to-end check of a running instance.
#
# Sourced by setup.sh, which owns CONTAINER, SECRETS, the output helpers and
# need_jq. verify_mounts comes from lib/paths.sh.

VERIFY_FAIL=0
_verify_chk() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; VERIFY_FAIL=1; fi
}

# _boot_log <lines-of-context-before-the-marker> - the current boot's slice of
# automations.log, from the last "daemon started" to the end of the file.
# Nothing empties the log on boot, so any check that greps the whole of it is
# reading history, not state.
_boot_log() {
  docker exec -e BACK="${1:-0}" "$CONTAINER" sh -c '
    L=$(grep -n "daemon started" /app/logs/automations.log 2>/dev/null | tail -1 | cut -d: -f1)
    [ -n "$L" ] || exit 0
    S=$((L > BACK ? L - BACK : 1))
    sed -n "${S},\$p" /app/logs/automations.log' 2>/dev/null
}

_verify_container() {
  head_ "Container"
  _verify_chk "container '${CONTAINER}' is running" "docker ps --filter name=^${CONTAINER}$ --format '{{.Names}}' | grep -qx ${CONTAINER}"
  _verify_chk "scheduler is PID 1"                  "docker exec ${CONTAINER} sh -c 'ps -o comm= -p 1' | grep -q scheduler"
  _verify_chk "content overlay mounted"             "docker exec ${CONTAINER} test -f /app/config/schedule.json"
  verify_mounts "$CONTAINER" || VERIFY_FAIL=1
  _verify_chk "secrets readable in container"       "docker exec ${CONTAINER} test -r /app/config/secrets.json"
  _verify_chk "interactive session alive"           "docker exec ${CONTAINER} tmux has-session -t zoidberg"
}

_verify_auth() { # <boot log>
  head_ "Claude authentication"
  if printf '%s\n' "$1" | grep -qi "not authenticated\|Please run /login"; then
    err "Claude CLI is NOT authenticated inside the container"
    info "  Fix it with: ./setup.sh login   (then: ./setup.sh login <code>)"
    VERIFY_FAIL=1
  else
    ok "no authentication errors since the last restart"
  fi
}

_verify_plugins() { # <boot log>
  head_ "Plugins"
  local line dis
  line="$(printf '%s\n' "$1" | grep "daemon started" | tail -1)"
  if [ -z "$line" ]; then
    err "scheduler never logged 'daemon started'"; VERIFY_FAIL=1
    return 0
  fi
  ok "${line#*] }"
  dis="$(printf '%s\n' "$1" | grep "features disabled" | tail -1)"
  [ -n "$dis" ] && printf '  %s\n' "${dis#*] }"
  return 0
}

# cmd_cron reported "adding: ..." for each entry and then died on a missing
# crontab, and verification still passed, so the owner was told the install was
# healthy while nothing would ever deploy. Check what is actually scheduled,
# not what setup.sh believes it wrote.
_verify_cron() {
  head_ "Host cron"
  if ! command -v crontab >/dev/null 2>&1; then
    err "crontab not installed - the deploy loop and daily restart cannot run"; VERIFY_FAIL=1
    return 0
  fi
  local ctab; ctab="$(crontab -l 2>/dev/null)"
  printf '%s\n' "$ctab" | grep -q "scripts/self-update.sh" \
    && ok "self-update scheduled" || { err "self-update NOT scheduled"; VERIFY_FAIL=1; }
  printf '%s\n' "$ctab" | grep -q "scripts/scheduled-restart.sh" \
    && ok "daily restart scheduled" || { err "daily restart NOT scheduled"; VERIFY_FAIL=1; }
}

# `run` sends its own handoff message straight after this, which proves
# outbound Telegram just as well. Sending a separate test message too means the
# owner gets two near-identical bot messages to finish one install, so run
# passes --no-message and lets the handoff be the proof.
_verify_telegram() { # <quiet 0|1>
  head_ "Telegram round trip"
  local tok cid
  tok="$(jq -r '.telegram.bot_token // ""' "$SECRETS" 2>/dev/null)"
  cid="$(jq -r '.telegram.chat_id // ""' "$SECRETS" 2>/dev/null)"
  if [ -z "$tok" ] || [ "$tok" = REPLACE_ME ] || [ -z "$cid" ]; then
    warn "telegram not configured, skipping round trip"
  elif [ "$1" = "1" ]; then
    ok "configured for chat ${cid} (handoff message follows)"
  elif curl -sS --max-time 15 "https://api.telegram.org/bot${tok}/sendMessage" \
      -d chat_id="$cid" -d text="Zoidberg check. If you can read this, outbound Telegram works." \
      | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "sent a test message to chat ${cid}, check Telegram"
  else
    err "could not send a Telegram message"; VERIFY_FAIL=1
  fi
}

# Everything after _verify_container reads the CURRENT boot only. Grepping the
# whole file pairs a fresh "daemon started" with a stale "features disabled"
# from an earlier run, and made one auth failure ever report NOT authenticated
# forever. "features disabled" is logged a few lines before "daemon started" in
# the same boot, so the window opens 30 lines ahead of the last boot marker.
cmd_verify() {
  need_jq
  VERIFY_FAIL=0
  local quiet=0
  [ "${1:-}" = "--no-message" ] && quiet=1

  _verify_container
  local boot; boot="$(_boot_log 30)"
  _verify_auth "$boot"
  _verify_plugins "$boot"
  _verify_cron
  _verify_telegram "$quiet"

  echo
  if [ "$VERIFY_FAIL" -eq 0 ]; then
    ok "verification passed"
  else
    err "verification found problems, see above"
  fi
  return $VERIFY_FAIL
}
