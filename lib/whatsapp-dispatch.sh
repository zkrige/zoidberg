#!/bin/bash
# whatsapp-dispatch.sh - Called directly by the webhook listener on POST.
# All required vars are inherited via environment from the parent plugin.

source "${REPO_DIR}/lib/common.sh" || exit 1
source "${REPO_DIR}/lib/evolution.sh" || true
# bot_channel_post/_wait_reply live in the claude-session plugin. This script runs
# as a fresh bash from the webhook listener, so plugin functions are not inherited
# from the scheduler — source it explicitly (pure defs, no side effects on source).
source "${REPO_DIR}/watchers/plugins/claude_session.sh" || exit 1

# Register Telegram as the notify channel (TG_TOKEN/TG_CHAT_ID exported by the plugin)
_wa_tg_notify() {
  local msg="$1"
  curl -sf "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    --data-urlencode "parse_mode=Markdown" \
    -o /dev/null 2>/dev/null
}
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  NOTIFY_FN="_wa_tg_notify"
fi

BUSY_LOCK="$WHATSAPP_BUSY"
_WA_CFG="$(content_path config.json)"

# Direct-forward: non-command self-chat messages go straight to Telegram, zero tokens
# Command messages start with "!" — strip the prefix and run Claude triage
_msg_body="${WHATSAPP_MSG_BODY:-}"
_media_type="${WHATSAPP_MEDIA_TYPE:-}"
_is_audio=false
if [ -z "$_media_type" ] || [ "$_media_type" = "text" ]; then
  _is_audio=false
elif printf '%s' "$_media_type" | grep -qiE "^(audio|ptt)$"; then
  _is_audio=true
fi

_msg_chat_jid="${WHATSAPP_MSG_CHAT_JID:-}"
_self_jid="${WHATSAPP_SELF_JID:-$(jq -r '.whatsapp.self_jid // empty' "$_WA_CFG" 2>/dev/null)}"

if [ "$_msg_chat_jid" != "$_self_jid" ]; then
  # Not the self-chat — never triage messages from other chats/groups
  exit 0
fi

if [ "$_is_audio" = "false" ] && [ -n "$_msg_body" ] && [ "${_msg_body:0:1}" != "!" ]; then
  # Plain text, no ! prefix — forward directly to Telegram
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -sf "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=*[WhatsApp]* ${_msg_body}" \
      --data-urlencode "parse_mode=Markdown" \
      -o /dev/null 2>/dev/null
  fi
  exit 0
fi

# Strip "!" prefix for command messages before passing to triage
if [ -n "$_msg_body" ] && [ "${_msg_body:0:1}" = "!" ]; then
  export WHATSAPP_MSG_BODY="${_msg_body:1}"
fi

# Read config — fall back to jq, then hardcoded defaults if env vars are empty
WHATSAPP_MODEL="${WHATSAPP_MODEL:-$(jq -r '.whatsapp.model // empty' "$_WA_CFG" 2>/dev/null)}"
WHATSAPP_MODEL="${WHATSAPP_MODEL:-sonnet}"
WHATSAPP_EFFORT="${WHATSAPP_EFFORT:-$(jq -r '.whatsapp.effort // empty' "$_WA_CFG" 2>/dev/null)}"
: "${WHATSAPP_EFFORT:=low}"
WHATSAPP_NOTIFY_FILTER="${WHATSAPP_NOTIFY_FILTER:-$(jq -r '.whatsapp.notify_filter // empty' "$_WA_CFG" 2>/dev/null)}"
: "${WHATSAPP_NOTIFY_FILTER:=ACTION REQUIRED|FYI}"
PROMPT_FILE="${WHATSAPP_PROMPT_FILE:-$(content_path agents/whatsapp-triage.txt)}"
[ -f "$PROMPT_FILE" ] || exit 1

# Atomic lock: ln -s fails if file already exists (no TOCTOU race).
# EXIT trap guarantees lock removal on crash, SIGTERM, or unexpected exit;
# without it, a killed dispatch orphans the lock and blocks all future webhooks.
if ! ln -s "$$" "$BUSY_LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rm -f "$BUSY_LOCK"' EXIT INT TERM

log "whatsapp: dispatching triage (webhook, instant)"

# Guardrails live in the session system prompt (see claude_session.sh), not here.
prompt="$(render_prompt "$PROMPT_FILE")"

cd "$REPO_DIR"
# Dispatch via the always-on interactive Claude session through bot-channel.
# Interactive transport keeps usage on subscription pool, not Agent SDK credit.
request_id="wa-$(date +%s)-$$"
if ! bot_channel_post "$request_id" "cron" "[task=whatsapp-triage] ${prompt}"; then
  log_failure "whatsapp" "channel post failed" "whatsapp"
  output=""
else
  output=$(bot_channel_wait_reply "$request_id" 1200)
  if [ $? -ne 0 ]; then
    log_failure "whatsapp" "channel reply timeout" "whatsapp"
  fi
fi

# Kill orphaned MCP processes
kill_orphaned_mcp

echo "$output" >> "${LOGS_DIR}/whatsapp-triage.log"
log "whatsapp: triage completed"

if [ -n "$output" ]; then
  if printf '%s' "$output" | grep -qiE "$WHATSAPP_NOTIFY_FILTER"; then
    notify "*[whatsapp-triage]*
${output}"
  else
    log "whatsapp: output filtered"
  fi
fi

rm -f "$BUSY_LOCK"
