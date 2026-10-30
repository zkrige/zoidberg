#!/bin/bash

# ---------------------------------------------------------------------------
# bot_channel_post - POST an event into the running Claude session
# Args: request_id  kind  content
# Returns 0 on success
# ---------------------------------------------------------------------------
bot_channel_post() {
  local request_id="$1" kind="$2" content="$3"
  if [ -z "$request_id" ] || [ -z "$content" ]; then
    log "bot_channel_post: missing request_id or content"
    return 1
  fi
  local payload
  payload=$(jq -nc \
    --arg id "$request_id" \
    --arg kind "${kind:-cron}" \
    --arg content "$content" \
    '{request_id: $id, kind: $kind, content: $content}')
  curl -sf --max-time 5 -X POST \
    -H 'content-type: application/json' \
    -d "$payload" \
    "http://127.0.0.1:${BOT_CHANNEL_PORT}/" >/dev/null
}

# ---------------------------------------------------------------------------
# bot_channel_wait_reply - block until reply file appears
# Args: request_id  timeout_seconds
# Echoes reply content to stdout, returns 0 on success, 1 on timeout, 2 when
# the session respawned mid-wait (the request is dead, not still running)
# ---------------------------------------------------------------------------
bot_channel_wait_reply() {
  local request_id="$1" timeout="${2:-600}"
  local reply_file="${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt"
  local gen_file="${STATE_DIR}/.session-generation"
  local start_gen
  start_gen=$(cat "$gen_file" 2>/dev/null)
  local start=$SECONDS
  while [ ! -f "$reply_file" ]; do
    if [ $(( SECONDS - start )) -ge "$timeout" ]; then
      log "bot_channel_wait_reply: timeout after ${timeout}s waiting for ${request_id}"
      return 1
    fi
    # The session that would answer this request_id was torn down and
    # respawned (e.g. a SIGHUP reload mid-wait) - the new session has no
    # memory of this request and can never call reply() for it. Fail fast
    # instead of blocking out the full timeout.
    if [ -n "$start_gen" ] && [ "$(cat "$gen_file" 2>/dev/null)" != "$start_gen" ]; then
      log "bot_channel_wait_reply: session respawned while waiting for ${request_id} - failing fast after $(( SECONDS - start ))s"
      return 2
    fi
    sleep 1
  done
  cat "$reply_file"
  rm -f "$reply_file"
  auto_push >/dev/null
}

# ---------------------------------------------------------------------------
# bot_channel_request - post and wait, all in one
# Args: kind  content  [timeout]
# Echoes reply to stdout, returns 0 on success
# ---------------------------------------------------------------------------
bot_channel_request() {
  local kind="$1" content="$2" timeout="${3:-600}"
  local request_id
  request_id="req-$(date +%s)-$$-$RANDOM"
  if ! bot_channel_post "$request_id" "$kind" "$content"; then
    return 1
  fi
  bot_channel_wait_reply "$request_id" "$timeout"
}
