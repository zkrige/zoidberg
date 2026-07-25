#!/bin/bash
# lib/telegram-session.sh - Telegram plugin session, prompt-section, and history helpers

# ---------------------------------------------------------------------------
# telegram_load_prompt_sections - Parse section headers from prompt-sections.txt
# ---------------------------------------------------------------------------
telegram_load_prompt_sections() {
  local sections_file="$(framework_prompt prompt-sections.txt)"
  if [ ! -f "$sections_file" ]; then
    log "telegram: WARNING - prompt-sections.txt not found"
    return
  fi
  _TG_SOURCE_MARKER=$(sed -n '1p' "$sections_file")
  _TG_MEDIA_HEADER=$(sed -n '/^---MEDIA_HEADER---$/,/^---/{/^---/d;p;}' "$sections_file")
  _TG_FEEDBACK_HEADER=$(sed -n '/^---FEEDBACK_HEADER---$/,/^---/{/^---/d;p;}' "$sections_file")
  _TG_CONTEXT_HEADER=$(sed -n '/^---CONTEXT_HEADER---$/,/^---/{/^---/d;p;}' "$sections_file")
  _TG_MEMORY_HEADER=$(sed -n '/^---MEMORY_HEADER---$/,/^---/{/^---/d;p;}' "$sections_file")
  _TG_SKILLS_HEADER=$(sed -n '/^---SKILLS_HEADER---$/,/^---/{/^---/d;p;}' "$sections_file")
}

# ---------------------------------------------------------------------------
# telegram_active_session_name - Return the current session name
# ---------------------------------------------------------------------------
telegram_active_session_name() {
  if [ -f "$ACTIVE_SESSION_FILE" ]; then
    cat "$ACTIVE_SESSION_FILE"
  else
    echo "default"
  fi
}

# ---------------------------------------------------------------------------
# telegram_msg_log - Return the message log path for the active session
# ---------------------------------------------------------------------------
telegram_msg_log() {
  local name
  name=$(telegram_active_session_name)
  echo "${SESSIONS_DIR}/${name}-messages.jsonl"
}

# ---------------------------------------------------------------------------
# telegram_log_exchange - Append one exchange to the active session message log
# ---------------------------------------------------------------------------
telegram_log_exchange() {
  local user_text="$1"
  local assistant_text="$2"
  local log_file="$3"
  jq -nc --arg ts "$(date -Iseconds)" --arg user "$user_text" --arg assistant "$assistant_text" \
    '{"ts":$ts,"user":$user,"assistant":$assistant}' >> "$log_file"
}

# ---------------------------------------------------------------------------
# telegram_build_history_section - Build a conversation transcript from the
# last WINDOW_SIZE exchanges in the active session message log
# ---------------------------------------------------------------------------
telegram_build_history_section() {
  local log_path
  log_path=$(telegram_msg_log)
  if [ ! -f "$log_path" ]; then
    echo ""
    return
  fi
  local transcript
  transcript=$(tail -n "$WINDOW_SIZE" "$log_path" | jq -r \
    '"[" + .ts + "] User: " + .user + "\nAssistant: " + .assistant' 2>/dev/null)
  if [ -z "$transcript" ]; then
    echo ""
    return
  fi
  printf '\n\n%s\n%s' "$_TG_CONTEXT_HEADER" "$transcript"
}

# ---------------------------------------------------------------------------
# telegram_build_skill_catalogue - Scan ~/.claude/skills/ for name+description
# Cached in TELEGRAM_SKILL_CATALOGUE for the session.
# ---------------------------------------------------------------------------
telegram_build_skill_catalogue() {
  if [ -n "$TELEGRAM_SKILL_CATALOGUE" ]; then
    return
  fi
  local skills_dir="${HOME}/.claude/skills"
  [ -d "$skills_dir" ] || return
  local lines=""
  for skill_file in "$skills_dir"/*/skill.md; do
    [ -f "$skill_file" ] || continue
    local name desc
    name=$(sed -n 's/^name: *//p' "$skill_file" | head -1)
    desc=$(sed -n 's/^description: *//p' "$skill_file" | head -1 | cut -c1-120)
    [ -z "$name" ] && continue
    lines="${lines}
- ${name}: ${desc}"
  done
  TELEGRAM_SKILL_CATALOGUE="$lines"
}
