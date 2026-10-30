#!/bin/bash

git_first_error_line() {
  local line
  line=$(grep -m1 -iE 'error|fatal|conflict|needs merge' <<<"$1")
  [ -n "$line" ] || line=$(head -1 <<<"$1")
  printf '%s' "$line"
}

git_failure_message() {
  printf '%s failed: %s: %s' "$1" "$2" "$(git_first_error_line "$3")"
}
