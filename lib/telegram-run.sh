#!/bin/bash
# lib/telegram-run.sh - Telegram plugin Claude dispatch + streaming runner

# NOTE: The _telegram_run_* helpers below are extracted sub-steps of
# telegram_run_claude. They rely on bash dynamic scope: each reads/writes
# locals declared in telegram_run_claude's frame (heartbeat_pid, request_id,
# reply_file, response, etc.) rather than threading many args. They are
# private to this function and must only be called from within it.

# ---------------------------------------------------------------------------
# _telegram_run_build_prompt - Assemble the channel-message body from the user's
# message plus any per-message media instructions, and nothing else.
#
# The stable context (guardrails, Telegram operating instructions, portable
# memory) lives in the session's REAL system prompt, built at spawn in
# claude_session.sh. Conversation continuity comes from the persistent session's
# own turns, NOT a re-pasted transcript. Re-embedding that bundle here made the
# model read each message as a "fake guardrails/CLAUDE.md reprint + fabricated
# prior-conversation transcript" and refuse genuine owner commands as injection.
# Keep the body minimal so it matches how real messages actually look.
# ---------------------------------------------------------------------------
_telegram_run_build_prompt() {
  local media_instructions=""
  if [ -n "$media_files" ]; then
    media_instructions=$(printf '\n%s\n%s\n' "$_TG_MEDIA_HEADER" "$media_files")
  fi

  full_prompt=$(printf '%s\n\n%s%s' "$_TG_SOURCE_MARKER" "$msg_text" "$media_instructions")
}

# ---------------------------------------------------------------------------
# _telegram_run_dispatch - Persist task state and post into the bot channel.
# ---------------------------------------------------------------------------
_telegram_run_dispatch() {
  printf '%s' "$msg_text" | head -c 80 > "$CURRENT_TASK_FILE"
  jq -nc --arg t "$msg_text" --arg m "${media_files:-}" '{text: $t, media: $m}' > "$IN_PROGRESS_FILE"

  # Dispatch via bot-channel into the always-on interactive Claude session.
  # Interactive transport keeps usage on subscription pool, not Agent SDK credit.
  request_id="tg-$(date +%s)-$$"
  echo "$request_id" > "$CLAUDE_PID_FILE"  # repurposed: holds active request_id for /cancel
  # Baseline the transcript so the stream loop can tell THIS turn's final
  # assistant message apart from any pre-existing one (salvage guard).
  _baseline_uuid=$(claude_session_last_assistant_uuid)
  if ! bot_channel_post "$request_id" "telegram" "$full_prompt"; then
    tg_send "Failed to dispatch message: channel unreachable."
    log_failure "channel_post" "$msg_text" "telegram" "request_id=${request_id}"
    kill $heartbeat_pid $typing_pid 2>/dev/null
    wait $heartbeat_pid $typing_pid 2>/dev/null
    rm -f "$CLAUDE_PID_FILE" "$CURRENT_TASK_FILE" "$IN_PROGRESS_FILE"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _telegram_run_status_tick - Emit/refresh the periodic "working" status line.
# ---------------------------------------------------------------------------
_telegram_run_status_tick() {
  if [ $(( SECONDS - _last_status_time )) -ge "$STATUS_INTERVAL" ]; then
    _last_status_time=$SECONDS
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local status_line
    if [ "$mins" -ge 18 ]; then
      status_line=$(printf '[%dm%02ds] working (auto-kill at 20m, /cancel to stop)' "$mins" "$secs")
    else
      status_line=$(printf '[%dm%02ds] working (/cancel to stop)' "$mins" "$secs")
    fi
    if [ -z "$_status_msg_id" ]; then
      _status_msg_id=$(tg_send_get_id "$status_line")
    else
      tg_edit "$_status_msg_id" "$status_line"
    fi
  fi
}

# ---------------------------------------------------------------------------
# _telegram_run_stream - Wait for the reply file, ticking status + wall timeout.
# ---------------------------------------------------------------------------
_telegram_run_stream() {
  local start_time=$SECONDS
  _last_status_time=$(( SECONDS - STATUS_INTERVAL + 30 ))
  local idle_streak=0
  local _reply_nudged=0

  while [ ! -f "$reply_file" ]; do
    local elapsed=$(( SECONDS - start_time ))

    _telegram_run_status_tick

    # Idle-fallback: the model can finish a turn (and even print the full
    # answer) without calling the `reply` tool, which leaves the orchestrator
    # blocked here until the wall-clock kill. Detect a genuine turn-end (pane
    # no longer busy for two consecutive polls) and, if a NEW text-bearing
    # assistant message exists since dispatch, ask for the reply properly
    # before falling back to scraping it.
    if claude_session_is_busy; then
      idle_streak=0
    else
      idle_streak=$(( idle_streak + 1 ))
      if [ "$idle_streak" -ge 2 ]; then
        local cur_uuid
        cur_uuid=$(claude_session_last_assistant_uuid)
        if [ -n "$cur_uuid" ] && [ "$cur_uuid" != "$_baseline_uuid" ]; then
          # Nudge once first. Scraping the transcript takes whatever the last
          # assistant message happens to be, which is not always the answer:
          # it has delivered a health-probe acknowledgement and a paragraph of
          # tool-failure narration to the owner in place of a real reply. One
          # reminder recovers the intended path, and costs a single turn.
          if [ "$_reply_nudged" -eq 0 ]; then
            _reply_nudged=1
            idle_streak=0
            log "telegram: turn ended without reply, nudging for ${request_id}"
            bot_channel_post "$request_id" "telegram" \
              "Your last turn ended without calling the \`reply\` tool, so the owner received nothing. Call \`reply\` now with request_id ${request_id} and the answer you meant to send. Send only the answer itself." \
              || log "telegram: nudge failed to post for ${request_id}"
            continue
          fi
          local salvaged
          salvaged=$(claude_session_last_assistant_text)
          if [ -n "$salvaged" ]; then
            printf '%s' "$salvaged" > "$reply_file"
            reply_salvaged=true
            log "telegram: reply tool not called even after a nudge, salvaged last assistant text (${#salvaged} chars) for ${request_id}"
            break
          fi
        fi
      fi
    fi

    # Wall-clock timeout: interrupt the running task in the tmux session
    if [ "$elapsed" -ge "$CLAUDE_WALL_TIMEOUT" ]; then
      claude_timed_out=true
      timeout_type="wall"
      tmux send-keys -t "$CLAUDE_TMUX_SESSION" Escape 2>/dev/null
      log "telegram: wall-clock timeout after ${CLAUDE_WALL_TIMEOUT}s, sent Escape"
      break
    fi

    sleep "$STREAM_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# _telegram_run_collect - Read the reply, clean up media + background pids + status.
# ---------------------------------------------------------------------------
_telegram_run_collect() {
  response=""
  if [ -f "$reply_file" ]; then
    response=$(cat "$reply_file")
    rm -f "$reply_file"
  fi

  if [ -n "$media_files" ]; then
    for f in $media_files; do
      rm -f "$f" 2>/dev/null
    done
  fi

  kill $heartbeat_pid $typing_pid 2>/dev/null
  wait $heartbeat_pid $typing_pid 2>/dev/null

  if [ -n "$_status_msg_id" ]; then
    tg_delete "$_status_msg_id"
  fi
}

# ---------------------------------------------------------------------------
# _telegram_run_reply - Send the final response (or a timeout/empty diagnostic).
# ---------------------------------------------------------------------------
_telegram_run_reply() {
  if [ -n "$response" ]; then
    local final="$response"
    if [ "$claude_timed_out" = true ] && [ "$timeout_type" = "wall" ]; then
      final=$(printf '%s\n\n[Auto-killed after %ds total runtime.]' "$final" "$CLAUDE_WALL_TIMEOUT")
    fi
    if [ "${#final}" -le 3800 ]; then
      tg_send "$final"
    else
      tg_send "$final"
    fi
  else
    local diag
    if [ "$claude_timed_out" = true ]; then
      diag="Task auto-killed after ${CLAUDE_WALL_TIMEOUT}s total runtime (no reply received before wall-clock limit)."
    else
      diag="No reply received from Claude session."
    fi
    tg_send "$diag"
    log_failure "empty_response" "$msg_text" "telegram" "request_id=${request_id}"
  fi
}

# ---------------------------------------------------------------------------
# _telegram_run_finalize - Auto-push, clear state, log exchange, prune memory.
# ---------------------------------------------------------------------------
_telegram_run_finalize() {
  # Auto-commit and push any changes the bot made
  telegram_auto_push

  rm -f "$CLAUDE_PID_FILE" "$CURRENT_TASK_FILE" "$IN_PROGRESS_FILE"

  # Log the exchange and prune memory if threshold reached
  if [ -n "$response" ]; then
    local this_msg_log
    this_msg_log=$(telegram_msg_log)
    telegram_log_exchange "$msg_text" "$response" "$this_msg_log"
    local count=0
    [ -f "$PRUNE_COUNTER_FILE" ] && count=$(cat "$PRUNE_COUNTER_FILE")
    count=$((count + 1))
    echo "$count" > "$PRUNE_COUNTER_FILE"
    if [ "$count" -ge "$PRUNE_THRESHOLD" ]; then
      telegram_prune_memory
    fi
  fi
}

# ---------------------------------------------------------------------------
# telegram_run_claude - Run a message through Claude with streaming output.
# Streams chunked updates to Telegram via editMessageText while Claude works.
# Heartbeat keeps the busy lock fresh so long sessions aren't reaped.
# Usage: telegram_run_claude <text> <media_files> [model] [effort]
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _telegram_run_setup_bg - Start heartbeat + typing loops, set caller's pids+trap.
# ---------------------------------------------------------------------------
_telegram_run_setup_bg() {
  # Heartbeat keeps the busy lock mtime fresh (prevents stale lock reaper)
  telegram_busy_heartbeat &
  heartbeat_pid=$!

  tg_typing_loop &
  typing_pid=$!

  # Ensure background processes are killed if this subshell is terminated.
  # Double quotes ON PURPOSE: bake the PIDs into the trap at set-time. The EXIT
  # trap fires after telegram_run_claude has returned and its locals are gone,
  # so deferred expansion would yield empty and kill nothing.
  # shellcheck disable=SC2064
  trap "kill $heartbeat_pid $typing_pid 2>/dev/null" EXIT
}

telegram_run_claude() {
  local msg_text="$1"
  local media_files="$2"
  local model="${3:-$DEFAULT_MODEL}"
  local effort="${4:-$DEFAULT_EFFORT}"

  local heartbeat_pid typing_pid full_prompt request_id response
  local _last_status_time="" _status_msg_id="" claude_timed_out=false timeout_type=""
  local _baseline_uuid="" reply_salvaged=false

  _telegram_run_setup_bg
  _telegram_run_build_prompt
  _telegram_run_dispatch || return

  local reply_file="${BOT_CHANNEL_REPLIES_DIR}/${request_id}.txt"
  _telegram_run_stream
  _telegram_run_collect
  _telegram_run_reply
  _telegram_run_finalize
}
