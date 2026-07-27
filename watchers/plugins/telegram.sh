#!/bin/bash
# plugins/telegram.sh - Telegram bot plugin for the scheduler orchestrator
#
# Required globals (set by orchestrator):
#   REPO_DIR, STATE_DIR, LOGS_DIR, CLAUDE_BIN, GUARDRAILS
#   MAX_CONCURRENT, DEFAULT_MODEL, DEFAULT_EFFORT
#   TG_TOKEN, TG_CHAT_ID, POLL_TIMEOUT, SCHEDULE_FILE
#
# Uses from cron.sh (sourced before this plugin, alphabetical order):
#   is_allowed_task, count_claude_processes

# ---------------------------------------------------------------------------
# State/config variable declarations
# ---------------------------------------------------------------------------
TELEGRAM_STATE="${STATE_DIR}/telegram-last-update"
BUSY_LOCK="/tmp/claude-telegram.busy"
BUSY_LOCK_MAX_AGE=300     # seconds before busy lock is considered stale (5 min)
STREAM_INTERVAL=2.0       # seconds between Telegram message updates during streaming
QUEUE_MUTEX="/tmp/claude-telegram-queue.mutex"
QUEUE_FILE="${STATE_DIR}/telegram-queue.json"
TG_MODEL_FILE="${STATE_DIR}/telegram-model.txt"
TG_EFFORT_FILE="${STATE_DIR}/telegram-effort.txt"
CLAUDE_PID_FILE="/tmp/claude-telegram.pid"
CURRENT_TASK_FILE="${STATE_DIR}/telegram-current-task.txt"
IN_PROGRESS_FILE="${STATE_DIR}/telegram-in-progress.json"
SESSIONS_DIR="${STATE_DIR}/sessions"
ACTIVE_SESSION_FILE="${STATE_DIR}/telegram-active-session.txt"
FEEDBACK_FILE="${STATE_DIR}/feedback.log"
PRUNE_THRESHOLD=15        # exchanges before memory pruning
CLAUDE_MAX_RUNTIME=600    # seconds of no output before Claude is killed (idle timeout)
CLAUDE_WALL_TIMEOUT=1200  # seconds absolute max runtime (wall-clock hard limit)
STATUS_INTERVAL=60        # seconds between status heartbeat updates
PRUNE_COUNTER_FILE="${STATE_DIR}/telegram-exchange-count.txt"
WINDOW_SIZE=10
TELEGRAM_SKILL_CATALOGUE=""

# Prompt section headers (loaded from file in telegram_init)
_TG_SOURCE_MARKER=""
_TG_MEDIA_HEADER=""
_TG_FEEDBACK_HEADER=""
_TG_CONTEXT_HEADER=""
_TG_MEMORY_HEADER=""
_TG_SKILLS_HEADER=""

# ---------------------------------------------------------------------------
# telegram_init - Source telegram-api, register as notification provider,
#                 build skill catalogue, create sessions dir
# ---------------------------------------------------------------------------
telegram_init() {
  source "${REPO_DIR}/lib/telegram-api.sh"
  source "${REPO_DIR}/lib/telegram-queue.sh"
  source "${REPO_DIR}/lib/telegram-session.sh"
  source "${REPO_DIR}/lib/telegram-run.sh"
  source "${REPO_DIR}/lib/claude-login.sh"
  source "${REPO_DIR}/lib/telegram-commands.sh"
  source "${REPO_DIR}/lib/telegram-process.sh"
  TG_TOKEN="$(get_secret '.telegram.bot_token')"
  TG_CHAT_ID="$(get_secret '.telegram.chat_id')"
  NOTIFY_FN="tg_send"
  telegram_load_prompt_sections
  telegram_build_skill_catalogue
  mkdir -p "$SESSIONS_DIR"

  # Clear stale locks from previous crashes
  rm -f "$BUSY_LOCK" "$CLAUDE_PID_FILE" "$CURRENT_TASK_FILE"

  _telegram_recover_crash
}

# _telegram_recover_crash - Recover interrupted message + drain orphaned queue
_telegram_recover_crash() {
  # Recover in-progress message interrupted by crash/restart
  if [ -f "$IN_PROGRESS_FILE" ]; then
    local recovered_text recovered_media
    recovered_text=$(jq -r '.text // empty' "$IN_PROGRESS_FILE" 2>/dev/null)
    recovered_media=$(jq -r '.media // empty' "$IN_PROGRESS_FILE" 2>/dev/null)
    rm -f "$IN_PROGRESS_FILE"
    if [ -n "$recovered_text" ]; then
      log "telegram: recovering interrupted message from previous run"
      _telegram_queue_inner "$recovered_text" "$recovered_media"
    fi
  fi

  # Drain orphaned queue from previous run
  if [ -f "$QUEUE_FILE" ]; then
    log "telegram: draining orphaned queue from previous run"
    telegram_drain_queue
  fi
}

# ---------------------------------------------------------------------------
# telegram_tick - Recover stale busy lock, then long-poll Telegram
# ---------------------------------------------------------------------------
telegram_tick() {
  _telegram_recover_stale_lock

  # Long-poll Telegram (blocks up to POLL_TIMEOUT seconds, returns instantly on message)
  telegram_poll || true
}

# _telegram_recover_stale_lock - Drop a stale busy lock / orphaned queue so it drains
_telegram_recover_stale_lock() {
  # Recover stale busy lock: if lock is older than BUSY_LOCK_MAX_AGE and no
  # claude child is processing a Telegram message, remove it so queued
  # messages can be drained on the next poll.
  if [ -L "$BUSY_LOCK" ] || [ -e "$BUSY_LOCK" ]; then
    # stat -c %Y reads mtime. For a symlink the heartbeat refreshes via
    # touch -h, so we get the symlink's own mtime.
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$BUSY_LOCK" 2>/dev/null || echo "$(date +%s)") ))
    if [ "$lock_age" -ge "$BUSY_LOCK_MAX_AGE" ]; then
      log "telegram: stale busy lock detected (${lock_age}s old), removing"
      rm -f "$BUSY_LOCK"
      telegram_drain_queue
    fi
  elif [ -f "$QUEUE_FILE" ]; then
    # Queue has messages but no busy lock (e.g. queued due to MAX_CONCURRENT
    # from a non-Telegram process that has since finished). Drain now.
    local running
    running=$(count_claude_processes)
    if [ "$running" -lt "$MAX_CONCURRENT" ]; then
      log "telegram: draining orphaned queue (no busy lock, ${running} processes)"
      telegram_drain_queue
    fi
  fi
}

# ---------------------------------------------------------------------------
# telegram_cleanup - Remove busy lock and queue mutex
# ---------------------------------------------------------------------------
telegram_cleanup() {
  rm -f "$BUSY_LOCK"
  rmdir "$QUEUE_MUTEX" 2>/dev/null
}

# ---------------------------------------------------------------------------
# telegram_on_wake - Clear stale busy lock, drain queue
# Called by orchestrator when a sleep/wake gap is detected
# ---------------------------------------------------------------------------
telegram_on_wake() {
  if [ -f "$BUSY_LOCK" ]; then
    log "telegram: clearing stale busy lock after wake"
    rm -f "$BUSY_LOCK"
  fi
  # Drain any queued messages immediately (orphan cleanup done by orchestrator)
  telegram_drain_queue
}

# ---------------------------------------------------------------------------
# telegram_poll - Long-poll Telegram for messages (blocks up to POLL_TIMEOUT)
# ---------------------------------------------------------------------------
telegram_poll() {
  if [ -z "$TG_TOKEN" ] || [ "$TG_TOKEN" = "null" ] || [ -z "$TG_CHAT_ID" ] || [ "$TG_CHAT_ID" = "null" ]; then
    sleep "$POLL_TIMEOUT"
    return
  fi

  local offset=0
  if [ -f "$TELEGRAM_STATE" ]; then
    offset=$(cat "$TELEGRAM_STATE")
    offset=$((offset + 1))
  fi

  local updates count
  updates=$(_telegram_poll_fetch "$offset") || return
  count=$(printf '%s' "$updates" | jq '.result | length')
  if [ "$count" = "0" ] || [ "$count" = "null" ]; then
    return
  fi

  for i in $(seq 0 $((count - 1))); do
    _telegram_process_update "$updates" "$i"
  done
}

# _telegram_poll_fetch - getUpdates long-poll; echo body, non-zero on empty/error
_telegram_poll_fetch() {
  local offset="$1" updates
  updates=$(curl -s --connect-timeout 10 --max-time $((POLL_TIMEOUT + 5)) \
    "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${offset}&timeout=${POLL_TIMEOUT}" 2>/dev/null)

  if [ $? -ne 0 ] || [ -z "$updates" ]; then
    return 1
  fi
  printf '%s' "$updates"
}

# _telegram_process_update - Parse one update, gate by chat id, dispatch to handler
_telegram_process_update() {
  local updates="$1" i="$2"
  local update_id msg_chat_id msg_text
  update_id=$(printf '%s' "$updates" | jq -r ".result[$i].update_id")
  msg_chat_id=$(printf '%s' "$updates" | jq -r ".result[$i].message.chat.id // empty")
  msg_text=$(printf '%s' "$updates" | jq -r ".result[$i].message.text // .result[$i].message.caption // empty")

  if [ -n "$update_id" ] && [ "$update_id" != "null" ]; then
    echo "$update_id" > "$TELEGRAM_STATE"
  fi

  if [ "$msg_chat_id" != "$TG_CHAT_ID" ]; then
    return
  fi

  _telegram_dispatch_message "$updates" "$i" "$msg_text"
}

# _telegram_dispatch_message - Extract media, default media-only text, hand to handler
_telegram_dispatch_message() {
  local updates="$1" i="$2" msg_text="$3"
  local media_files
  media_files=$(_telegram_extract_media "$updates" "$i")

  # Skip if no text AND no media
  if [ -z "$msg_text" ] && [ -z "$media_files" ]; then
    return
  fi

  # Default text for media-only messages
  if [ -z "$msg_text" ] && [ -n "$media_files" ]; then
    msg_text="[sent media - see attached files]"
  fi

  telegram_handle_message "$msg_text" "$media_files"
}

# _telegram_dl_field - Download media at jq path with ext; append path to media_files
# Appends to caller-scoped media_files (dynamic scope).
_telegram_dl_field() {
  local msg="$1" jq_path="$2" ext="$3"
  local file_id
  file_id=$(printf '%s' "$msg" | jq -r "${jq_path} // empty")
  if [ -n "$file_id" ]; then
    local path
    path=$(tg_download_file "$file_id" "$ext")
    if [ -n "$path" ]; then
      media_files="${media_files} ${path}"
    fi
  fi
}

# _telegram_dl_document - Download document with extension derived from file_name
_telegram_dl_document() {
  local msg="$1" msg_prefix="$2"
  local doc_id doc_name
  doc_id=$(printf '%s' "$msg" | jq -r "${msg_prefix}.document.file_id // empty")
  doc_name=$(printf '%s' "$msg" | jq -r "${msg_prefix}.document.file_name // empty")
  if [ -n "$doc_id" ]; then
    local doc_ext=".bin"
    if [ -n "$doc_name" ] && [[ "$doc_name" == *.* ]]; then
      doc_ext=$(printf '%s' ".${doc_name##*.}" | tr -cd 'a-zA-Z0-9.')
    fi
    local doc_path
    doc_path=$(tg_download_file "$doc_id" "$doc_ext")
    if [ -n "$doc_path" ]; then
      media_files="${media_files} ${doc_path}"
    fi
  fi
}

# _telegram_extract_media - Download photo/voice/audio/document; echo space-joined paths
_telegram_extract_media() {
  local msg="$1" i="$2"
  local media_files=""
  local msg_prefix=".result[$i].message"

  # Photo: array of sizes, grab the largest (last)
  _telegram_dl_field "$msg" "${msg_prefix}.photo[-1].file_id" ".jpg"
  _telegram_dl_field "$msg" "${msg_prefix}.voice.file_id" ".ogg"
  _telegram_dl_field "$msg" "${msg_prefix}.audio.file_id" ".mp3"
  _telegram_dl_document "$msg" "$msg_prefix"

  printf '%s' "$media_files" | sed 's/^ //'
}
