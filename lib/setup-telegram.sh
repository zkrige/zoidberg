#!/bin/bash
# lib/setup-telegram.sh - token validation, chat-id discovery, and the
# installer's own outbound messages.
#
# Sourced by setup.sh, which owns what is used here: CONTAINER, SECRETS, the
# output helpers, need_jq, require_files and json_write.

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

TG_BOT_USERNAME=""
TG_CHAT_IDS=""

# _tg_validate_token <token> - bot username into TG_BOT_USERNAME.
_tg_validate_token() {
  local me; me="$(api "$1" getMe)"
  if [ "$(printf '%s' "$me" | jq -r '.ok // false')" != "true" ]; then
    err "Telegram rejected that token."
    printf '%s\n' "$(printf '%s' "$me" | jq -r '.description // "no response from Telegram"')"
    info "Re-check the token from @BotFather and run this again."
    return 1
  fi
  TG_BOT_USERNAME="$(printf '%s' "$me" | jq -r '.result.username')"
  ok "token valid, bot is @${TG_BOT_USERNAME}"
}

# _tg_wait_chat_id <token> - poll until someone has messaged the bot; every
# chat id seen lands in TG_CHAT_IDS, one per line.
_tg_wait_chat_id() {
  local waited=0 interval=3 timeout="${CHATID_TIMEOUT:-180}"
  TG_CHAT_IDS=""
  while [ "$waited" -lt "$timeout" ]; do
    TG_CHAT_IDS="$(api "$1" getUpdates | jq -r '[.result[]?.message.chat.id] | unique | .[]' 2>/dev/null)"
    [ -n "$TG_CHAT_IDS" ] && return 0
    sleep "$interval"; waited=$((waited + interval))
    [ $((waited % 15)) -eq 0 ] && info "  still waiting for a message... (${waited}s)"
  done
  err "No message seen after ${timeout}s."
  info "Note that a bot which has already been running will have consumed"
  info "older messages, so send a NEW one now, then re-run: setup.sh run"
  return 1
}

# _tg_require_single_chat - discovery cannot choose between two people who both
# messaged the bot while it was listening.
_tg_require_single_chat() {
  local count; count="$(printf '%s\n' "$TG_CHAT_IDS" | grep -c .)"
  [ "$count" -le 1 ] && return 0
  err "Saw more than one chat id, cannot choose for you:"
  printf '%s\n' "$TG_CHAT_IDS" | sed 's/^/  /'
  info "Set the right one with: setup.sh chatid <id>"
  return 1
}

# _tg_consume_updates <token> - consume the updates discovery just read.
# getUpdates without an offset is non-destructive, so without this the bot
# starts, polls, finds the "hi" the owner only sent as a setup step, and
# answers it. That reply arrives in the middle of the setup instructions and
# reads like the bot talking to itself.
_tg_consume_updates() {
  local last_id
  last_id="$(api "$1" getUpdates | jq -r '[.result[]?.update_id] | max // empty' 2>/dev/null)"
  [ -n "$last_id" ] || return 0
  api "$1" "getUpdates?offset=$((last_id + 1))" >/dev/null 2>&1
  ok "cleared the setup messages so the bot does not reply to them"
}

cmd_telegram() {
  need_jq; require_files
  local token="${1:-}"
  [ -n "$token" ] || { err "usage: setup.sh telegram <token>"; exit 1; }

  head_ "Validating token"
  _tg_validate_token "$token" || exit 1

  json_write "$SECRETS" --arg tok "$token" '.telegram.bot_token = $tok' || exit 1
  chmod 600 "$SECRETS"
  ok "token stored in secrets.json (mode 600)"

  head_ "Discovering your chat id"
  info "Send any message to @${TG_BOT_USERNAME} in Telegram now (for example: hi)."
  _tg_wait_chat_id "$token" || exit 1

  _tg_require_single_chat || exit 1
  cmd_chatid "$TG_CHAT_IDS"
  _tg_consume_updates "$token"
}

cmd_chatid() {
  need_jq; require_files
  local cid="${1:-}"
  [ -n "$cid" ] || { err "usage: setup.sh chatid <id>"; exit 1; }
  json_write "$SECRETS" --arg cid "$cid" '.telegram.chat_id = $cid' || exit 1
  chmod 600 "$SECRETS"
  ok "chat_id ${cid} stored in secrets.json"
}
