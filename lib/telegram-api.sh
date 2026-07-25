#!/usr/bin/env bash
# lib/telegram-api.sh
# Pure Telegram Bot API helper functions.
#
# Required globals (set by caller before sourcing or calling these functions):
#   TG_TOKEN   - Telegram bot token
#   TG_CHAT_ID - Telegram chat ID to send messages to
#
# Optional (set by orchestrator if available):
#   log_failure, trigger_evolution - from lib/evolution.sh

# Markdown -> HTML rendering (_md_to_html). Sourced before any consumer below.
source "${REPO_DIR}/lib/telegram-md.sh"

_tg_api() {
  local endpoint="$1"; shift
  # Disable link previews on message sends/edits. Hostile referrer domains that
  # land in report bodies (e.g. ghost-spam GA sources) otherwise get auto-fetched
  # by Telegram and rendered as preview cards advertising their cloaked content.
  local extra=()
  case "$endpoint" in
    sendMessage|editMessageText) extra=(-d disable_web_page_preview=true) ;;
  esac
  local result
  result=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/${endpoint}" \
    -d chat_id="$TG_CHAT_ID" ${extra[@]+"${extra[@]}"} "$@" 2>/dev/null)
  # Retry once on 429 rate limit, sleeping the retry_after interval
  if printf '%s' "$result" | jq -e '.error_code == 429' >/dev/null 2>&1; then
    local retry_after
    retry_after=$(printf '%s' "$result" | jq -r '.parameters.retry_after // 5' 2>/dev/null)
    sleep "${retry_after:-5}"
    result=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/${endpoint}" \
      -d chat_id="$TG_CHAT_ID" ${extra[@]+"${extra[@]}"} "$@" 2>/dev/null)
  fi
  printf '%s' "$result"
}

_tg_check_ok() {
  printf '%s' "$1" | jq -e '.ok == true' >/dev/null 2>&1
}

_tg_error_desc() {
  printf '%s' "$1" | jq -r '.description // "unknown error"' 2>/dev/null
}

_tg_log_failure() {
  local context="$1"
  local error="$2"
  log "telegram-api: ${context}: ${error}"
  if type -t log_failure >/dev/null 2>&1; then
    log_failure "send_failed" "${context}: ${error}" "telegram-api"
  fi
  # trigger_evolution is now called automatically by log_failure
}

_tg_strip_markdown() {
  # Remove markdown formatting that breaks Telegram's parser
  printf '%s' "$1" | sed 's/[*_`\[\\]//g'
}

_tg_send_chunk() {
  local chunk="$1"
  local html result html_error
  html=$(_md_to_html "$chunk")
  result=$(_tg_api sendMessage -d parse_mode="HTML" --data-urlencode text="$html")
  if _tg_check_ok "$result"; then return 0; fi

  html_error=$(_tg_error_desc "$result")
  result=$(_tg_api sendMessage --data-urlencode text="$chunk")
  if _tg_check_ok "$result"; then
    _tg_log_failure "tg_send" "HTML failed, sent plain: ${html_error}"
    return 0
  fi

  _tg_log_failure "tg_send" "$(_tg_error_desc "$result")"
  return 1
}

# Append $para to global $chunk (blank-line separated); flush + restart if over $limit.
# Reads/writes globals: chunk. Args: para, limit.
_tg_chunk_append() {
  local para="$1" limit="$2" candidate
  if [ -n "$chunk" ] && [ -n "$para" ]; then
    candidate="${chunk}"$'\n\n'"${para}"
  elif [ -n "$para" ]; then
    candidate="${para}"
  else
    candidate="${chunk}"
  fi
  if [ "${#candidate}" -le "$limit" ]; then
    chunk="$candidate"
  else
    [ -n "$chunk" ] && _tg_send_chunk "$chunk"
    chunk="$para"
  fi
}

# Stream $msg paragraph by paragraph into $chunk, flushing full chunks as they fill.
# Reads/writes globals: chunk. Args: msg, limit.
_tg_chunk_stream() {
  local msg="$1" limit="$2" para="" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      _tg_chunk_append "$para" "$limit"
      para=""
    else
      [ -n "$para" ] && para="${para}"$'\n'"${line}" || para="$line"
    fi
  done <<< "$msg"
  [ -n "$para" ] && _tg_chunk_append "$para" "$limit"
}

tg_send() {
  local msg="$1"
  local limit=3800

  # Fast path: message fits in one chunk
  if [ "${#msg}" -le "$limit" ]; then
    _tg_send_chunk "$msg"
    return
  fi

  # Split on blank lines, accumulating paragraphs into chunks under the limit.
  local chunk=""
  _tg_chunk_stream "$msg" "$limit"
  [ -n "$chunk" ] && _tg_send_chunk "$chunk"
}

tg_send_get_id() {
  local msg="$1"
  local truncated
  truncated=$(printf '%s' "$msg" | head -c 4000)

  local html result
  html=$(_md_to_html "$truncated")
  result=$(_tg_api sendMessage -d parse_mode="HTML" --data-urlencode text="$html")
  if _tg_check_ok "$result"; then
    printf '%s' "$result" | jq -r '.result.message_id // empty'
    return 0
  fi

  # Fallback: plain text
  result=$(_tg_api sendMessage --data-urlencode text="$truncated")
  if _tg_check_ok "$result"; then
    printf '%s' "$result" | jq -r '.result.message_id // empty'
    return 0
  fi

  _tg_log_failure "tg_send_get_id" "$(_tg_error_desc "$result")"
  return 1
}

tg_edit() {
  local msg_id="$1"
  local msg="$2"
  local truncated
  truncated=$(printf '%s' "$msg" | head -c 4000)

  local html result
  html=$(_md_to_html "$truncated")
  result=$(_tg_api editMessageText -d message_id="$msg_id" -d parse_mode="HTML" --data-urlencode text="$html")
  if _tg_check_ok "$result"; then return 0; fi

  local error
  error=$(_tg_error_desc "$result")

  # "message is not modified" is not a real error (content unchanged)
  if [[ "$error" == *"message is not modified"* ]]; then return 0; fi

  # HTML failed — retry without parse_mode
  result=$(_tg_api editMessageText -d message_id="$msg_id" --data-urlencode text="$truncated")
  if _tg_check_ok "$result"; then return 0; fi

  _tg_log_failure "tg_edit" "$error"
  # Fallback: send as new message
  tg_send "$msg"
}

tg_delete() {
  local msg_id="$1"
  _tg_api deleteMessage -d "message_id=${msg_id}" >/dev/null 2>&1
}

tg_typing() {
  _tg_api sendChatAction -d action="typing" >/dev/null 2>&1
}

tg_typing_loop() {
  while true; do
    tg_typing
    sleep 4
  done
}

tg_download_file() {
  local file_id="$1"
  local ext="$2"
  local file_info file_path

  file_info=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getFile?file_id=${file_id}" 2>/dev/null)
  file_path=$(printf '%s' "$file_info" | jq -r '.result.file_path // empty')

  if [ -z "$file_path" ]; then
    _tg_log_failure "tg_download_file" "empty file_path for file_id=${file_id}"
    return 1
  fi

  _tg_fetch_file "$file_path" "$ext"
}

# Download remote $file_path into a fresh local tmp file; print path on success.
_tg_fetch_file() {
  local file_path="$1" ext="$2" local_path
  mkdir -p /tmp/zoidberg
  chmod 700 /tmp/zoidberg
  local_path="/tmp/zoidberg/tg-$(date +%s)-${BASHPID:-$$}${ext}"
  curl -s -o "$local_path" "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}" 2>/dev/null

  if [ -f "$local_path" ] && [ -s "$local_path" ]; then
    printf '%s' "$local_path"
    return 0
  fi
  _tg_log_failure "tg_download_file" "download failed for ${file_path}"
  return 1
}
