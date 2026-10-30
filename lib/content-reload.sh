#!/bin/bash

CONTENT_RELOAD_PATHS='^agents/'

content_prompts_changed() {
  local repo_dir="$1" from="$2" to="$3"
  git -C "$repo_dir" diff --name-only "$from" "$to" | grep -qE "$CONTENT_RELOAD_PATHS"
}
