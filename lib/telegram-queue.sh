#!/bin/bash
# lib/telegram-queue.sh - Telegram plugin queue, lock, heartbeat, and auto-push helpers

# ---------------------------------------------------------------------------
# telegram_drain_queue - Drain queued messages in background
# ---------------------------------------------------------------------------
telegram_drain_queue() {
  if telegram_take_queue; then
    local drain_model="$DEFAULT_MODEL" drain_effort="$DEFAULT_EFFORT"
    [ -f "$TG_MODEL_FILE" ] && drain_model=$(cat "$TG_MODEL_FILE")
    [ -f "$TG_EFFORT_FILE" ] && drain_effort=$(cat "$TG_EFFORT_FILE")
    log "telegram: draining queued messages (${drain_model}/${drain_effort})"
    (
      ln -s "${BASHPID:-$$}" "$BUSY_LOCK" 2>/dev/null || true
      telegram_run_claude "$TAKEN_TEXT" "$TAKEN_MEDIA" "$drain_model" "$drain_effort"
      while telegram_take_queue; do
        telegram_run_claude "$TAKEN_TEXT" "$TAKEN_MEDIA" "$drain_model" "$drain_effort"
      done
      rm -f "$BUSY_LOCK"
    ) &
  fi
}

# ---------------------------------------------------------------------------
# telegram_with_lock - Mutex wrapper (mkdir-based, atomic)
# Usage: telegram_with_lock <command> [args...]
# ---------------------------------------------------------------------------
telegram_with_lock() {
  while ! mkdir "$QUEUE_MUTEX" 2>/dev/null; do
    sleep 0.05
  done
  "$@"
  local rc=$?
  rmdir "$QUEUE_MUTEX" 2>/dev/null
  return $rc
}

# ---------------------------------------------------------------------------
# _telegram_queue_inner - Inner function for adding to queue (runs under lock)
# ---------------------------------------------------------------------------
_telegram_queue_inner() {
  local msg_text="$1"
  local media_files="$2"
  local entry
  entry=$(jq -nc --arg t "$msg_text" --arg m "$media_files" '{text: $t, media: $m}')

  if [ -f "$QUEUE_FILE" ]; then
    local tmp="${QUEUE_FILE}.tmp"
    jq --argjson e "$entry" '. + [$e]' "$QUEUE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$QUEUE_FILE"
  else
    printf '[%s]' "$entry" > "$QUEUE_FILE"
  fi
}

# ---------------------------------------------------------------------------
# telegram_queue_message - Atomically add a message to the queue file
# ---------------------------------------------------------------------------
telegram_queue_message() {
  telegram_with_lock _telegram_queue_inner "$1" "$2"
  log "telegram: queued message: ${1}"
}

# ---------------------------------------------------------------------------
# _telegram_take_inner - Inner function for draining queue (runs under lock)
# ---------------------------------------------------------------------------
_telegram_take_inner() {
  if [ ! -f "$QUEUE_FILE" ]; then
    return 1
  fi

  local count
  count=$(jq 'length' "$QUEUE_FILE" 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "0" ] || [ "$count" = "null" ]; then
    rm -f "$QUEUE_FILE"
    return 1
  fi

  # Snapshot the queue, then delete the original (both under the lock)
  cp "$QUEUE_FILE" "${QUEUE_FILE}.drain.$$"
  rm -f "$QUEUE_FILE"
  return 0
}

# ---------------------------------------------------------------------------
# telegram_take_queue - Atomically read and delete queue. Sets TAKEN_TEXT and TAKEN_MEDIA.
# Returns 1 if queue is empty/missing.
# ---------------------------------------------------------------------------
telegram_take_queue() {
  TAKEN_TEXT=""
  TAKEN_MEDIA=""

  telegram_with_lock _telegram_take_inner
  if [ $? -ne 0 ]; then
    return 1
  fi

  # Parse the snapshot outside the lock (no contention on .drain file)
  local count
  count=$(jq 'length' "${QUEUE_FILE}.drain.$$" 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" = "0" ]; then
    rm -f "${QUEUE_FILE}.drain.$$"
    return 1
  fi

  TAKEN_TEXT=$(jq -r '[.[].text] | join("\n")' "${QUEUE_FILE}.drain.$$")
  TAKEN_MEDIA=$(jq -r '[.[].media | select(. != null and . != "")] | join(" ")' "${QUEUE_FILE}.drain.$$")
  rm -f "${QUEUE_FILE}.drain.$$"
  log "telegram: took ${count} messages from queue"
  return 0
}

# _telegram_prune_run - Send memory to the cron channel and write back result
_telegram_prune_run() {
  local memory_file="$1" prune_prompt_file="$2"
  local prune_prompt memory_contents pruned
  prune_prompt=$(cat "$prune_prompt_file")
  memory_contents=$(cat "$memory_file")
  pruned=$(bot_channel_request "cron" "$(printf '%s\n\n%s' "$prune_prompt" "$memory_contents")" 300)
  if [ -n "$pruned" ]; then
    printf '%s' "$pruned" > "$memory_file"
    log "telegram: memory pruned successfully"
  else
    log "telegram: memory prune failed, keeping current memory"
  fi
}

# ---------------------------------------------------------------------------
# telegram_prune_memory - Prune memory.md using Sonnet when exchange threshold
# is reached. Resets counter on both success and failure.
# ---------------------------------------------------------------------------
telegram_prune_memory() {
  log "telegram: pruning memory (${PRUNE_THRESHOLD} exchanges reached)"
  local memory_file="${REPO_DIR}/state/memory.md"
  if [ ! -f "$memory_file" ] || [ ! -s "$memory_file" ]; then
    echo "0" > "$PRUNE_COUNTER_FILE"
    return
  fi
  local prune_prompt_file="$(framework_prompt memory-prune-prompt.txt)"
  if [ ! -f "$prune_prompt_file" ]; then
    log "telegram: WARNING - memory-prune-prompt.txt not found, skipping prune"
    echo "0" > "$PRUNE_COUNTER_FILE"
    return
  fi
  _telegram_prune_run "$memory_file" "$prune_prompt_file"
  echo "0" > "$PRUNE_COUNTER_FILE"
}

# ---------------------------------------------------------------------------
# telegram_busy_heartbeat - Touch the busy lock every 30s to prove liveness
# ---------------------------------------------------------------------------
telegram_busy_heartbeat() {
  # touch -h updates the symlink's own mtime via lutimes(2).
  # Without -h, touch follows the symlink and (a) updates the wrong mtime
  # (stale check uses lstat, which reads the symlink's own mtime), and
  # (b) creates a junk regular file at the symlink target path.
  while true; do
    [ -L "$BUSY_LOCK" ] && touch -h "$BUSY_LOCK" 2>/dev/null
    sleep 30
  done
}

# ---------------------------------------------------------------------------
# telegram_auto_push - Commit and push any changes the bot made to repos
# ---------------------------------------------------------------------------
telegram_auto_push() {
  local pushed=""
  for repo_dir in /app /home/claude/.claude/skills; do
    if [ -d "$repo_dir/.git" ] && (! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet || [ -n "$(git -C "$repo_dir" ls-files --others --exclude-standard)" ]); then
      git -C "$repo_dir" add -A
      local summary
      summary=$(git -C "$repo_dir" diff --cached --stat | tail -1)
      git -C "$repo_dir" commit -m "auto: bot update ($summary)" 2>/dev/null || continue
      if git -C "$repo_dir" push origin main 2>/dev/null; then
        local repo_name
        repo_name=$(basename "$(git -C "$repo_dir" remote get-url origin)" .git)
        pushed="${pushed:+${pushed}, }${repo_name}"
        log "telegram: auto-pushed to ${repo_name}"
      fi
    fi
  done
  [ -n "$pushed" ] && tg_send "[auto-push] $pushed"
}
