#!/usr/bin/env bash
# lib/telegram-md.sh
# Markdown -> Telegram HTML rendering. Sourced by lib/telegram-api.sh.

_md_to_html() {
  # Convert Claude markdown output to Telegram HTML
  python3 "${REPO_DIR}/lib/telegram-md.py" "$1"
}
