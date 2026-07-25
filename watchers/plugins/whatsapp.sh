#!/usr/bin/env bash
# whatsapp.sh - WhatsApp webhook plugin.
# Listens for webhook POSTs from whatsapp-mcp-extended bridge and dispatches
# the whatsapp-triage task instantly (no cron delay).
#
# Required globals (set by orchestrator):
#   REPO_DIR, STATE_DIR, LOGS_DIR, CLAUDE_BIN, GUARDRAILS,
#   DEFAULT_MODEL, DEFAULT_EFFORT, TG_TOKEN, TG_CHAT_ID
#
# Plugin contract: whatsapp_init, whatsapp_tick, whatsapp_cleanup, whatsapp_on_wake

# Read config from config/config.json and config/schedule.json
_WA_CONFIG="$(content_path config.json)"
WHATSAPP_WEBHOOK_PORT=$(jq -r '.whatsapp.webhook_port // 8769' "$_WA_CONFIG" 2>/dev/null)
WHATSAPP_BRIDGE_API=$(jq -r '.whatsapp.bridge_api // "http://localhost:8080/api"' "$_WA_CONFIG" 2>/dev/null)
WHATSAPP_SELF_JID=$(jq -r '.whatsapp.self_jid // empty' "$_WA_CONFIG" 2>/dev/null)
WHATSAPP_LISTENER_PID=""
WHATSAPP_BUSY="/tmp/claude-whatsapp-busy"
_WA_SECRET_FILE="${STATE_DIR}/whatsapp-webhook-secret.txt"
if [ -f "$_WA_SECRET_FILE" ]; then
  WHATSAPP_WEBHOOK_SECRET="$(cat "$_WA_SECRET_FILE")"
else
  WHATSAPP_WEBHOOK_SECRET="$(head -c 16 /dev/urandom | xxd -p)"
  echo "$WHATSAPP_WEBHOOK_SECRET" > "$_WA_SECRET_FILE"
fi
WHATSAPP_MODEL=$(jq -r '.whatsapp.model // "sonnet"' "$_WA_CONFIG" 2>/dev/null)
WHATSAPP_EFFORT=$(jq -r '.whatsapp.effort // "low"' "$_WA_CONFIG" 2>/dev/null)
WHATSAPP_NOTIFY_FILTER=$(jq -r '.whatsapp.notify_filter // "ACTION REQUIRED|FYI"' "$_WA_CONFIG" 2>/dev/null)

# ---------------------------------------------------------------------------
# whatsapp_init - Start webhook listener, register webhook with bridge
# ---------------------------------------------------------------------------
whatsapp_init() {
  # Start the Python webhook listener in background
  whatsapp_start_listener

  # Register webhook with bridge (idempotent - bridge ignores dupes)
  whatsapp_register_webhook

  log "whatsapp: initialized (webhook listener on port ${WHATSAPP_WEBHOOK_PORT})"
}

# ---------------------------------------------------------------------------
# whatsapp_tick - Check for trigger file and dispatch if present
# ---------------------------------------------------------------------------
whatsapp_tick() {
  # Ensure listener is still running
  if [ -n "$WHATSAPP_LISTENER_PID" ] && ! kill -0 "$WHATSAPP_LISTENER_PID" 2>/dev/null; then
    log "whatsapp: listener died, restarting"
    whatsapp_start_listener
  fi
}

# ---------------------------------------------------------------------------
# whatsapp_cleanup - Kill listener, remove locks
# ---------------------------------------------------------------------------
whatsapp_cleanup() {
  [ -n "$WHATSAPP_LISTENER_PID" ] && kill "$WHATSAPP_LISTENER_PID" 2>/dev/null
  rm -f "$WHATSAPP_BUSY"
}

# ---------------------------------------------------------------------------
# whatsapp_on_wake - Clear stale busy lock
# ---------------------------------------------------------------------------
whatsapp_on_wake() {
  rm -f "$WHATSAPP_BUSY"
}

# ---------------------------------------------------------------------------
# whatsapp_start_listener - Start Python HTTP server for webhook POSTs
# ---------------------------------------------------------------------------
whatsapp_start_listener() {
  # Kill any existing listener on the port
  fuser -k ${WHATSAPP_WEBHOOK_PORT}/tcp 2>/dev/null || lsof -ti :${WHATSAPP_WEBHOOK_PORT} 2>/dev/null | xargs kill 2>/dev/null

  # Export everything the dispatch script needs
  : "${WHATSAPP_MODEL:=sonnet}"
  : "${WHATSAPP_EFFORT:=low}"
  : "${WHATSAPP_NOTIFY_FILTER:=ACTION REQUIRED|FYI}"
  export REPO_DIR STATE_DIR LOGS_DIR CLAUDE_BIN GUARDRAILS
  export TG_TOKEN TG_CHAT_ID
  export WHATSAPP_BUSY WHATSAPP_MODEL WHATSAPP_EFFORT WHATSAPP_NOTIFY_FILTER WHATSAPP_WEBHOOK_SECRET
  export WHATSAPP_PROMPT_FILE="$(content_path agents/whatsapp-triage.txt)"

  python3 -c "
import http.server, subprocess, os, threading, json, hmac, hashlib

DISPATCH = '${REPO_DIR}/lib/whatsapp-dispatch.sh'

SECRET = os.environ.get('WHATSAPP_WEBHOOK_SECRET', '')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b''
        if SECRET:
            sig = self.headers.get('X-Webhook-Signature', '')
            expected = 'sha256=' + hmac.HMAC(SECRET.encode(), body, hashlib.sha256).hexdigest()
            if not hmac.compare_digest(sig, expected):
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'unauthorized')
                return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
        try:
            payload = json.loads(body)
            msg = payload.get('message', {})
            if not msg.get('is_from_me', False):
                return
            env = os.environ.copy()
            env['WHATSAPP_MSG_BODY'] = msg.get('content', '')
            env['WHATSAPP_MEDIA_TYPE'] = msg.get('media_type', '')
            env['WHATSAPP_MSG_CHAT_JID'] = msg.get('chat_jid', '')
        except Exception:
            return
        threading.Thread(target=lambda: subprocess.run(['bash', DISPATCH], env=env), daemon=True).start()
    def log_message(self, *args):
        pass

http.server.HTTPServer(('127.0.0.1', ${WHATSAPP_WEBHOOK_PORT}), Handler).serve_forever()
" &
  WHATSAPP_LISTENER_PID=$!

  sleep 0.5
  if ! kill -0 "$WHATSAPP_LISTENER_PID" 2>/dev/null; then
    log_failure "whatsapp" "listener failed to start (pid ${WHATSAPP_LISTENER_PID})"
    WHATSAPP_LISTENER_PID=""
  fi
}

# ---------------------------------------------------------------------------
# whatsapp_register_webhook - Register webhook with the extended bridge
# ---------------------------------------------------------------------------
whatsapp_register_webhook() {
  # Check if webhook already exists
  local existing
  local raw_response
  raw_response=$(curl -sf -H "X-API-Key: ${WHATSAPP_BRIDGE_API_KEY:-}" "${WHATSAPP_BRIDGE_API}/webhooks" 2>/dev/null)
  if [ $? -ne 0 ]; then
    log "whatsapp: WARNING - could not reach bridge API to check existing webhooks"
    return
  fi
  existing=$(printf '%s' "$raw_response" | jq -r '.data[]? | select(.name == "zoidberg") | .id' 2>/dev/null)

  if [ -n "$existing" ]; then
    log "whatsapp: webhook already registered (id: ${existing})"
    return
  fi

  # Create webhook with all-messages trigger; is_from_me filtering happens in the listener
  local result
  result=$(curl -sf -X POST "${WHATSAPP_BRIDGE_API}/webhooks" \
    -H "X-API-Key: ${WHATSAPP_BRIDGE_API_KEY:-}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"zoidberg\",
      \"webhook_url\": \"http://127.0.0.1:${WHATSAPP_WEBHOOK_PORT}/webhook\",
      \"secret_token\": \"${WHATSAPP_WEBHOOK_SECRET}\",
      \"enabled\": true,
      \"triggers\": [{
        \"trigger_type\": \"all\",
        \"trigger_value\": \"\",
        \"match_type\": \"exact\",
        \"enabled\": true
      }]
    }" 2>/dev/null)

  if [ $? -ne 0 ]; then
    log "whatsapp: WARNING - curl failed to POST webhook registration"
    return
  fi

  local webhook_id
  webhook_id=$(printf '%s' "$result" | jq -r '.data.id // empty')

  if [ -z "$webhook_id" ]; then
    log "whatsapp: WARNING - failed to register webhook: $(printf '%s' "$result" | jq -r '.error // empty')"
    return
  fi

  log "whatsapp: webhook registered (id: ${webhook_id}, trigger: self-chat)"
}
