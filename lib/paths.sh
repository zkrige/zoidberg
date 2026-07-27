#!/usr/bin/env bash
# paths.sh - Host-side path resolution, shared by install.sh, setup.sh and
# scripts/self-update.sh.
#
# Host side is *_PATH: the names docker-compose.yml interpolates. In-container
# it is *_DIR, which is a different thing and must not be confused with these:
# CONTENT_DIR is always /app/config inside the container (lib/common.sh), while
# CONTENT_PATH is wherever the overlay lives on the host.
#
# The paths are written to the repo's .env so docker compose, host cron and a
# hand-run `docker compose up` all agree without anyone editing a file, and
# verify_mounts checks the running container actually got them.

# self-update.sh has no output helpers of its own. install.sh and setup.sh both
# define these before sourcing, and theirs win.
if ! declare -F ok   >/dev/null; then ok()   { printf '[ok] %s\n' "$*"; }; fi
if ! declare -F warn >/dev/null; then warn() { printf '[warn] %s\n' "$*" >&2; }; fi
if ! declare -F err  >/dev/null; then err()  { printf '[error] %s\n' "$*" >&2; }; fi

# path_check <name> <value> - absolute, no whitespace, no trailing slash.
#
# All three are load-bearing. A relative value turns a bind mount into a named
# volume reference and fails the whole compose project with "refers to
# undefined volume", taking the five-minute deploy cron down with it. Whitespace
# breaks the unquoted crontab lines setup.sh writes. A trailing slash empties
# the basename compose derives the project name from.
path_check() {
  local name="$1" val="$2"
  case "$val" in
    /*) ;;
    *)  err "${name}=${val} is not an absolute path"; return 1 ;;
  esac
  case "$val" in
    *[[:space:]]*) err "${name}=${val} contains whitespace"; return 1 ;;
  esac
  case "$val" in
    */) err "${name}=${val} ends in a slash"; return 1 ;;
  esac
  return 0
}

# env_value_check <KEY=VALUE> - path-shaped keys get the full check; the rest
# only have to be free of whitespace, which is all compose tolerates unquoted.
env_value_check() {
  local key="${1%%=*}" val="${1#*=}"
  case "$key" in
    *_PATH) path_check "$key" "$val"; return $? ;;
  esac
  case "$val" in
    *[[:space:]]*) err "${key}=${val} contains whitespace"; return 1 ;;
  esac
  return 0
}

# env_file_load <file> - set the KEY=value lines that are not already set.
#
# Deliberately not `source`: compose's .env is data, not bash. Sourcing it
# executes it (a backtick in a path is code execution, as root under cron) and
# expands ~ and $VAR against a different HOME. Only KEY=value, comments and
# blank lines are understood; anything else stops the caller rather than being
# guessed at.
env_file_load() {
  local file="$1" line key
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    if [ "$key" = "$line" ] || ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      err "${file}: cannot parse line: ${line}"
      return 1
    fi
    if [ -z "${!key+x}" ]; then
      export "${key}=${line#*=}"
    fi
  done < "$file"
  return 0
}

# env_file_write <file> <KEY=VALUE>... - create if absent, add missing keys
# only, never rewrite a value that is already there. install.sh's header
# promises it overwrites no existing config, and a relocated install has these
# hand-set.
#
# Mode 644, not 600: on Linux the repo is chowned to 1000:1000, and an operator
# running `docker compose` as themselves cannot read a 600 file, at which point
# compose silently falls back to the built-in defaults. ENV_SUDO is set by
# install.sh, where the clone is still root-owned.
env_file_write() {
  local file="$1"; shift
  local body="# Host paths for docker compose. Written by setup.sh, safe to edit."
  local add="" names="" kv key
  if [ -f "$file" ]; then body="$(cat "$file")"; fi
  for kv in "$@"; do
    env_value_check "$kv" || return 1
    key="${kv%%=*}"
    if ! printf '%s\n' "$body" | grep -q "^${key}="; then
      add="${add}${kv}"$'\n'; names="${names}${key} "
    fi
  done
  if [ -z "$add" ]; then ok "${file} already has every key"; return 0; fi
  printf '%s\n%s' "$body" "$add" | ${ENV_SUDO:-} tee "$file" >/dev/null || return 1
  ${ENV_SUDO:-} chmod 644 "$file"
  ok "${file}: added ${names% }"
  return 0
}

# legacy_alias <new> <old> - the *_DIR host names predate this split and are
# what install.sh's usage text and people's runbooks still say. Keep taking
# them, but say which name supplied the value.
legacy_alias() {
  local new="$1" old="$2"
  if [ -n "${!new+x}" ]; then return 0; fi
  if [ -z "${!old+x}" ]; then return 0; fi
  warn "${old} is the old name for ${new}; using ${old}=${!old}"
  export "${new}=${!old}"
  return 0
}

# resolve_host_paths - fill CONTENT_PATH and SKILLS_PATH, then validate all
# three. REPO_PATH must already be set: every caller knows where it is and
# nothing else can tell it. Precedence is the environment, then the repo's
# .env, then the sibling-directory layout docker-compose.yml defaults to.
resolve_host_paths() {
  legacy_alias CONTENT_PATH CONTENT_DIR
  legacy_alias SKILLS_PATH SKILLS_DIR
  env_file_load "${REPO_PATH}/.env" || return 1
  local parent; parent="$(dirname "$REPO_PATH")"
  : "${CONTENT_PATH:=${parent}/zoidberg-config}"
  : "${SKILLS_PATH:=${parent}/claude-skills}"
  export REPO_PATH CONTENT_PATH SKILLS_PATH
  path_check REPO_PATH    "$REPO_PATH"    || return 1
  path_check CONTENT_PATH "$CONTENT_PATH" || return 1
  path_check SKILLS_PATH  "$SKILLS_PATH"  || return 1
  return 0
}

# detect_ssh_key - docker-compose.yml bind-mounts a host key in for git over
# ssh. Its default is ~/.ssh/id_rsa, and on a host with no key dockerd creates
# that path as a root-owned DIRECTORY, after which the operator's own ssh is
# broken. Name a real key when there is one; otherwise name a directory that
# is always there, which docker/entrypoint.sh's `[ -f ]` guard skips.
detect_ssh_key() {
  local k
  for k in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
    if [ -f "$k" ]; then printf '%s' "$k"; return 0; fi
  done
  printf '%s' "${REPO_PATH}/docker"
  return 0
}

# env_write_defaults - the keys every install needs in .env. One list, two
# callers: install.sh runs it while the clone is still root-owned (hence
# ENV_SUDO), setup.sh runs it for hand clones and for installs that predate
# the file. resolve_host_paths must have run first.
#
# COMPOSE_PROJECT_NAME is pinned because compose otherwise derives it from the
# project directory's basename, and that namespaces the claude-home and
# wa-bridge-store named volumes. Moving an install would orphan both: Claude
# auth survives by luck through the /app/store/volume-backup restore in
# docker/entrypoint.sh, the WhatsApp pairing does not.
env_write_defaults() {
  env_file_write "${REPO_PATH}/.env" \
    "REPO_PATH=${REPO_PATH}" \
    "CONTENT_PATH=${CONTENT_PATH}" \
    "SKILLS_PATH=${SKILLS_PATH}" \
    "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-zoidberg}" \
    "SSH_KEY_PATH=$(detect_ssh_key)"
}

# verify_mounts <container> - assert what each host mount actually points AT,
# not just that the path inside the container reads. An install whose compose
# fell back to the built-in defaults looks completely healthy from inside the
# container, right up to the moment something writes to the wrong tree.
# Called from setup.sh's cmd_verify.
verify_mounts() {
  local container="$1" mounts pair want dest got rc=0
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.Source}}{{"\n"}}{{end}}' \
    "$container" 2>/dev/null)"
  for pair in "/app:${REPO_PATH}" "/app/config:${CONTENT_PATH}" \
              "/app/skills:${SKILLS_PATH}" "/home/claude/.claude/skills:${SKILLS_PATH}"; do
    dest="${pair%%:*}"; want="${pair#*:}"
    got="$(printf '%s\n' "$mounts" | awk -v k="$dest" '$1 == k { print $2 }')"
    if [ "$got" = "$want" ]; then
      ok "mount ${dest} <- ${want}"
    else
      err "mount ${dest} is '${got:-missing}', expected ${want}"; rc=1
    fi
  done
  return $rc
}
