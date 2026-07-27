#!/bin/bash
# install.sh - Deterministic bootstrap for the Zoidberg framework.
#
# Runs on Linux or macOS. The bot always runs in a Linux container, so the host
# only needs Docker; an Apple Silicon Mac builds the same arm64 image a Pi does.
#
# This script does ONLY prerequisite, deterministic work: checks/installs
# system packages, clones the framework, seeds a content overlay, creates
# mount points, and generates a bridge API key. It never authors application
# config, never talks to Telegram, never starts the container, and never
# makes judgment calls. It finishes by running ./setup.sh run, which does the
# rest; SKIP_SETUP=1 stops after the filesystem work instead.
#
# Safe to run via:
#   curl -fsSL https://raw.githubusercontent.com/zkrige/zoidberg/main/install.sh | bash
# or from a local clone:
#   ./install.sh
# Piped, stdin is the script itself rather than the terminal, so prompts are
# read from /dev/tty instead.
#
# Idempotent: safe to re-run. Never overwrites existing config or secrets.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (plain, no em dashes; colour only when attached to a TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

info()  { printf '%s\n' "$*"; }
ok()    { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
header(){ printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Overridable so you can install to a different prefix, or point at a fork or a
# local clone. Only REPO_PATH is settled here, because it is what the clone
# needs; the overlay and skills paths are resolved from lib/paths.sh once the
# clone exists, which is also what puts them in .env for docker compose. The
# old REPO_DIR spelling still works.
REPO_URL="${REPO_URL:-https://github.com/zkrige/zoidberg.git}"
if [ -z "${REPO_PATH:-}" ] && [ -n "${REPO_DIR:-}" ]; then
  warn "REPO_DIR is the old name for REPO_PATH; using REPO_DIR=${REPO_DIR}"
fi
REPO_PATH="${REPO_PATH:-${REPO_DIR:-/opt/zoidberg}}"

usage() {
  cat <<EOF
install.sh - Bootstrap the Zoidberg framework on a Linux or macOS host.

Usage:
  ./install.sh [--help]

What it does:
  1. Detects the platform. Linux and macOS are supported; the bot itself
     always runs in a Linux container, so the host only has to run Docker.
  2. Checks prerequisites: git, curl, jq, docker (+ docker compose plugin),
     claude CLI. Offers to install any that are missing (asks first; never
     installs silently, never forces), using apt-get on Linux and Homebrew on
     macOS. Reads prompts from /dev/tty so it can still ask when piped; exits
     non-zero if there is no terminal at all.
  3. Clones the framework to ${REPO_PATH} (leaves it alone if already present).
  4. Seeds a content overlay beside it from examples/content/ (leaves it alone
     if already present).
  5. Creates the skills directory and the config/ + skills/ mount points
     inside the repo directory.
  6. Generates a random WhatsApp bridge API key into secrets.json if unset.
  7. Ensures .features in the seeded config.json is {telegram: true, whatsapp: false}.
  8. Writes .env with the three host paths, so docker compose, host cron and a
     hand-run compose command all mount the same directories. Existing values
     are never changed.
  9. chowns the three directories to uid:gid 1000:1000 (the container's
     user). Skipped on macOS, where Docker Desktop maps ownership itself.
  10. Runs ./setup.sh run, which builds and starts the container, takes your
     Telegram token, signs Claude in, installs host cron, and verifies.

Everything through step 9 is deterministic and authors no config. Step 10 is
where the install becomes interactive: it stops for a bot token and for you to
approve a Claude sign-in URL, and it is resumable if interrupted.

Environment:
  SKIP_SETUP=1   Stop after step 9. Finish later with:
                   cd ${REPO_PATH} && ./setup.sh run
  REPO_URL       Clone from a fork instead of the default.
  REPO_PATH, CONTENT_PATH, SKILLS_PATH
                 Install to different paths. Nothing else needs editing:
                 they are written to .env and docker compose reads it.
                 Unset, the overlay and skills default to siblings of
                 REPO_PATH. The old REPO_DIR/CONTENT_DIR/SKILLS_DIR names
                 still work and say so when used.

Options:
  --help    Show this message and exit.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. OS / arch detection
#
# The bot always runs in a Linux container. The host only has to run Docker, so
# Linux and macOS are both fine: an Apple Silicon Mac is arm64 exactly like the
# single-board computers this targets, and builds the identical image.
# ---------------------------------------------------------------------------
header "Checking platform"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

case "$OS_NAME" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *)
    err "Unsupported platform: ${OS_NAME}."
    info "This installer targets a Linux or macOS host running Docker."
    info "Windows is not a supported install target."
    exit 1
    ;;
esac
ok "${OS_NAME} (${ARCH_NAME})"

# Privilege escalation. Fresh server images and container bases very often run
# as root with no sudo installed, so calling sudo unconditionally fails with
# "sudo: command not found". Resolve it once and use $SUDO for filesystem work.
#
# On macOS this is only ever `sudo`: Homebrew refuses to run as root, and a
# root-owned install would leave Docker Desktop unable to read the bind mounts
# it later shares into the container.
if [ "$PLATFORM" = macos ] && [ "$(id -u)" -eq 0 ]; then
  err "Do not run this as root on macOS."
  info "Homebrew refuses to run as root, and Docker Desktop shares files as"
  info "your own user. Re-run it as yourself; it will ask for sudo when it"
  info "needs to create directories under /opt."
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  ok "running as root"
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
  ok "running as $(id -un), using sudo"
else
  err "Not running as root and sudo is not installed."
  info "Re-run this as root, or install sudo first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Prerequisite check + opt-in install
# ---------------------------------------------------------------------------
header "Checking prerequisites"

# Run as `curl ... | bash`, this script is itself being read from stdin, so
# `[ -t 0 ]` is false even though the operator is sitting right there. Treating
# that as "cannot ask" aborted the documented install command on any host
# missing git or jq, which is most fresh hosts.
#
# stdin cannot simply be reassigned to fix it: bash is still reading the rest of
# this file from that pipe, and taking it away hangs the script mid-run. So
# stdin is left alone and prompts read from the terminal device directly.
#
# The open is probed in a subshell because with no controlling terminal (CI, a
# container without -t) /dev/tty exists and passes -r but opening it fails with
# ENXIO.
TTY_DEV=""
if (: < /dev/tty) 2>/dev/null; then
  TTY_DEV=/dev/tty
fi

IS_TTY=0
if [ -n "$TTY_DEV" ]; then
  IS_TTY=1
fi

MISSING_ANY=0

confirm_and_run() {
  local prompt_msg="$1"
  local cmd="$2"

  if [ "$IS_TTY" -ne 1 ]; then
    err "Not attached to a terminal, cannot prompt for confirmation."
    info "Run this yourself, then re-run install.sh:"
    info "  $cmd"
    exit 1
  fi

  printf '%s\n' "$prompt_msg"
  printf 'Run this now? [y/N] '
  read -r reply < "$TTY_DEV"
  case "$reply" in
    y|Y|yes|Yes|YES)
      info "Running: $cmd"
      eval "$cmd"
      ;;
    *)
      err "Skipped. Install it manually, then re-run install.sh:"
      info "  $cmd"
      exit 1
      ;;
  esac
}

check_prereq() {
  local bin="$1" install_cmd="$2" label="$3"

  if command -v "$bin" >/dev/null 2>&1; then
    ok "${label}: found ($(command -v "$bin"))"
    return
  fi

  MISSING_ANY=1
  warn "${label}: not found"
  confirm_and_run "  Install with: $install_cmd" "$install_cmd"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "${label}: installed"
  else
    err "${label} still not found after install attempt."
    exit 1
  fi
}

# How to install an ordinary package, per platform. Homebrew is deliberately
# never prefixed with $SUDO: it refuses to run as root and says so.
pkg_install_cmd() {
  if [ "$PLATFORM" = macos ]; then
    printf 'brew install %s' "$1"
  else
    printf '%s apt-get update && %s apt-get install -y %s' "$SUDO" "$SUDO" "$1"
  fi
}

if [ "$PLATFORM" = macos ]; then
  # Everything else on macOS is installed through Homebrew, so it is the one
  # prerequisite the script cannot bootstrap for you: installing Homebrew runs
  # its own interactive installer and wants its own confirmation.
  if command -v brew >/dev/null 2>&1; then
    ok "homebrew: found ($(command -v brew))"
  else
    err "homebrew: not found."
    info "It is how this installs the rest on macOS. Install it, then re-run:"
    info '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
fi

check_prereq git "$(pkg_install_cmd git)" "git"
check_prereq curl "$(pkg_install_cmd curl)" "curl"
check_prereq jq "$(pkg_install_cmd jq)" "jq"

# The whole deploy loop is host cron. Minimal server and container images
# routinely omit it, and setup.sh then dies on `crontab: command not found`
# after reporting that it added the entries. macOS ships cron in the base
# system, so this is a Linux concern only.
if [ "$PLATFORM" = linux ]; then
  check_prereq crontab "$SUDO apt-get update && $SUDO apt-get install -y cron" "cron"
fi

if command -v docker >/dev/null 2>&1; then
  ok "docker: found ($(command -v docker))"
else
  MISSING_ANY=1
  warn "docker: not found"
  if [ "$PLATFORM" = macos ]; then
    confirm_and_run "  Install with: brew install --cask docker" "brew install --cask docker"
  else
    confirm_and_run "  Install with: curl -fsSL https://get.docker.com | $SUDO sh" \
      "curl -fsSL https://get.docker.com | $SUDO sh"
  fi
  if command -v docker >/dev/null 2>&1; then
    ok "docker: installed"
  else
    err "docker still not found after install attempt."
    [ "$PLATFORM" = macos ] && info "Open Docker Desktop once to finish its setup, then re-run this."
    exit 1
  fi
fi

# On macOS the CLI exists whether or not the daemon is running, and every
# docker command later in this script and in setup.sh would fail with a
# connection error that reads like a broken install. Ask for it now instead.
if ! docker info >/dev/null 2>&1; then
  err "The Docker daemon is not responding."
  if [ "$PLATFORM" = macos ]; then
    info "Start Docker Desktop and wait for it to say it is running, then re-run this."
    info "Set it to open at login so the bot comes back after a reboot:"
    info "  Docker Desktop > Settings > General > Start Docker Desktop when you sign in"
  else
    info "Start it with: $SUDO systemctl start docker"
  fi
  exit 1
fi
ok "docker daemon: responding"

if docker compose version >/dev/null 2>&1; then
  ok "docker compose: found"
else
  MISSING_ANY=1
  warn "docker compose plugin: not found"
  if [ "$PLATFORM" = macos ]; then
    # Compose ships inside Docker Desktop; a separate install would not help.
    err "docker compose is missing from this Docker Desktop install."
    info "Update Docker Desktop, or reinstall it with: brew install --cask docker"
    exit 1
  fi
  confirm_and_run "  Install with: $SUDO apt-get update && $SUDO apt-get install -y docker-compose-plugin" \
    "$SUDO apt-get update && $SUDO apt-get install -y docker-compose-plugin"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose: installed"
  else
    err "docker compose plugin still not found after install attempt."
    exit 1
  fi
fi

# The Claude installer puts its binary in ~/.local/bin and tells you to add that
# to PATH from your shell config, which does nothing for the shell running this
# script. Without this, a successful install is followed immediately by a failed
# `command -v claude` and the run aborts having actually done the work.
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) PATH="${HOME}/.local/bin:${PATH}"; export PATH ;;
esac

if command -v claude >/dev/null 2>&1; then
  ok "claude CLI: found ($(command -v claude))"
else
  MISSING_ANY=1
  warn "claude CLI: not found"
  confirm_and_run "  Install with: curl -fsSL https://claude.ai/install.sh | bash" \
    "curl -fsSL https://claude.ai/install.sh | bash"
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI: installed"
    info "  It lives in ~/.local/bin. Add this to your shell config to keep it on PATH:"
    info "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  else
    err "claude CLI still not found after install attempt."
    exit 1
  fi
fi

if [ "$MISSING_ANY" -eq 0 ]; then
  ok "All prerequisites already present."
fi

# ---------------------------------------------------------------------------
# 3. Clone the framework
# ---------------------------------------------------------------------------
header "Framework repo"

if [ -d "$REPO_PATH/.git" ]; then
  ok "${REPO_PATH} already present. Leaving it alone."
else
  info "Cloning ${REPO_URL} to ${REPO_PATH}..."
  $SUDO mkdir -p "$(dirname "$REPO_PATH")"
  $SUDO git clone "$REPO_URL" "$REPO_PATH"
  ok "Cloned to ${REPO_PATH}"
fi

# The clone is what makes the shared path library reachable, which is why the
# overlay and skills paths are resolved here and not at the top: this script is
# routinely run straight off a curl pipe with no repo on disk yet. Resolution
# order is the environment, then an existing .env, then siblings of the repo.
# It also validates all three, so a path that would break compose or the
# crontab stops the install before anything else is created.
# shellcheck source=SCRIPTDIR/lib/paths.sh
source "${REPO_PATH}/lib/paths.sh"
resolve_host_paths || exit 1
ok "overlay ${CONTENT_PATH}, skills ${SKILLS_PATH}"

# ---------------------------------------------------------------------------
# 4. Seed the content overlay from examples/content/
# ---------------------------------------------------------------------------
header "Content overlay"

EXAMPLES_DIR="${REPO_PATH}/examples/content"

if [ -d "$CONTENT_PATH" ] && [ -n "$(ls -A "$CONTENT_PATH" 2>/dev/null)" ]; then
  ok "${CONTENT_PATH} already present and non-empty. Leaving it alone."
else
  if [ ! -d "$EXAMPLES_DIR" ]; then
    err "examples/content/ not found at ${EXAMPLES_DIR}. Cannot seed overlay."
    exit 1
  fi
  info "Seeding ${CONTENT_PATH} from examples/content/..."
  $SUDO mkdir -p "$CONTENT_PATH/agents" "$CONTENT_PATH/scripts"
  $SUDO cp "$EXAMPLES_DIR/config.example.json" "$CONTENT_PATH/config.json"
  $SUDO cp "$EXAMPLES_DIR/secrets.example.json" "$CONTENT_PATH/secrets.json"
  $SUDO cp "$EXAMPLES_DIR/schedule.json" "$CONTENT_PATH/schedule.json"
  $SUDO cp "$EXAMPLES_DIR/agents/"*.txt "$CONTENT_PATH/agents/"
  $SUDO cp "$EXAMPLES_DIR/scripts/"* "$CONTENT_PATH/scripts/"
  ok "Seeded ${CONTENT_PATH}"
fi

# ---------------------------------------------------------------------------
# 5. Skills dir + in-repo mount points
# ---------------------------------------------------------------------------
header "Directories"

$SUDO mkdir -p "$SKILLS_PATH"
ok "${SKILLS_PATH}: present"

$SUDO mkdir -p "${REPO_PATH}/config" "${REPO_PATH}/skills"
ok "${REPO_PATH}/config and ${REPO_PATH}/skills mount points: present"

# ---------------------------------------------------------------------------
# 6. Generate the WhatsApp bridge API key if unset
# ---------------------------------------------------------------------------
header "Bridge API key"

SECRETS_FILE="${CONTENT_PATH}/secrets.json"
CURRENT_KEY="$($SUDO jq -r '.whatsapp.bridge_api_key // empty' "$SECRETS_FILE" 2>/dev/null || true)"

if [ -n "$CURRENT_KEY" ]; then
  ok "whatsapp.bridge_api_key already set. Leaving it alone."
else
  NEW_KEY="$(openssl rand -hex 32)"
  $SUDO jq --arg key "$NEW_KEY" '.whatsapp = ((.whatsapp // {}) + {"bridge_api_key": $key})' \
    "$SECRETS_FILE" | $SUDO tee "${SECRETS_FILE}.tmp" >/dev/null
  $SUDO mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
  ok "Generated a random bridge API key into secrets.json"
fi

# secrets.json holds the Telegram bot token and any backup credentials. tee
# creates files 644 and mv preserves that, so tighten it explicitly rather
# than leaving it world readable.
$SUDO chmod 600 "$SECRETS_FILE"
ok "secrets.json permissions set to 600"

# ---------------------------------------------------------------------------
# 7. Ensure .features defaults: telegram on, everything else off
# ---------------------------------------------------------------------------
header "Feature flags"

CONFIG_FILE="${CONTENT_PATH}/config.json"
CURRENT_FEATURES="$($SUDO jq -r 'if has("features") then "present" else "absent" end' "$CONFIG_FILE")"

if [ "$CURRENT_FEATURES" = "present" ]; then
  ok ".features already set in config.json. Leaving it alone."
else
  $SUDO jq '.features = {"telegram": true, "whatsapp": false}' "$CONFIG_FILE" \
    | $SUDO tee "${CONFIG_FILE}.tmp" >/dev/null
  $SUDO mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  ok "Set .features = {telegram: true, whatsapp: false} in config.json"
fi

# ---------------------------------------------------------------------------
# 8. Host paths into .env, which docker compose reads for its mount sources
#
# Before the ownership step, because on Linux the clone is still root-owned
# here and the write needs $SUDO. The same writer runs from setup.sh, so a
# hand clone and an install that predates this end up with the same file.
# ---------------------------------------------------------------------------
header "Host paths"

# shellcheck disable=SC2034  # read by env_file_write in lib/paths.sh
ENV_SUDO="$SUDO"
env_write_defaults

# ---------------------------------------------------------------------------
# 9. Ownership - the container runs as uid:gid 1000:1000
# ---------------------------------------------------------------------------
header "Ownership"

# On macOS the container's uid 1000 is irrelevant: Docker Desktop shares bind
# mounts through a virtual filesystem that maps them to whatever uid the
# container asks for. What does matter is that these directories were just
# created with sudo, so they belong to root. Left that way the operator needs
# sudo to edit their own schedule.json. Hand them back.
if [ "$PLATFORM" = macos ]; then
  if $SUDO chown -R "$(id -u):$(id -g)" "$REPO_PATH" "$CONTENT_PATH" "$SKILLS_PATH" 2>/dev/null; then
    ok "ownership given to $(id -un) (Docker Desktop maps uids into the container)"
  else
    warn "could not set ownership on every file; you may need sudo to edit"
    warn "your content overlay at ${CONTENT_PATH}"
  fi
  $SUDO chmod 600 "$SECRETS_FILE" 2>/dev/null || true
else
  # Deliberately non-fatal. chown -R can partially fail (odd filesystems, NFS,
  # files owned by someone else) and under set -e that would abort the script at
  # its very last step, after every real change has already succeeded, leaving
  # the user with an error and no idea what to do next. Ownership is a
  # convenience so the container's uid 1000 can write; warn and carry on.
  if $SUDO chown -R 1000:1000 "$REPO_PATH" "$CONTENT_PATH" "$SKILLS_PATH" 2>/dev/null; then
    ok "chown -R 1000:1000 applied to ${REPO_PATH}, ${CONTENT_PATH}, ${SKILLS_PATH}"
  else
    warn "could not set ownership on every file (harmless unless the container"
    warn "cannot write; fix with: chown -R 1000:1000 ${REPO_PATH} ${CONTENT_PATH})"
  fi

  # That chown is what makes git refuse to touch these repos afterwards: the
  # host cron runs self-update.sh as root, git sees a repo owned by uid 1000 and
  # aborts with "detected dubious ownership". The deploy loop then fails every
  # five minutes on a brand new install, logging to a file nobody reads. Declare
  # the three directories safe for whoever is about to own the crontab.
  for d in "$REPO_PATH" "$CONTENT_PATH" "$SKILLS_PATH"; do
    git config --global --get-all safe.directory 2>/dev/null | grep -qx "$d" \
      || git config --global --add safe.directory "$d" 2>/dev/null || true
  done
  ok "git safe.directory set for $(id -un) on all three directories"
fi

# ---------------------------------------------------------------------------
# Handoff: run setup, or say how to
# ---------------------------------------------------------------------------
header "Filesystem ready"

# Splitting this in two was about what each half does, not about making the
# operator run two commands. Chain straight into setup so installing is one
# command. SKIP_SETUP=1 stops here for anyone provisioning a host now and
# configuring it later.
if [ "${SKIP_SETUP:-0}" = "1" ]; then
  cat <<EOF

${C_BOLD}Stopping here because SKIP_SETUP=1. Nothing is running yet.${C_RESET}

Finish whenever you like:

  ${C_GREEN}cd ${REPO_PATH} && ./setup.sh run${C_RESET}

EOF
  exit 0
fi

if [ "$IS_TTY" -ne 1 ]; then
  cat <<EOF

${C_BOLD}Filesystem is ready, but nothing is running yet.${C_RESET}

The rest needs to ask you for a Telegram token and a sign-in code, and there
is no terminal attached here. Run this from a terminal to finish:

  ${C_GREEN}cd ${REPO_PATH} && ./setup.sh run${C_RESET}

EOF
  exit 0
fi

cat <<EOF

Prerequisites are in place and the framework is at ${REPO_PATH}.
Starting setup. It stops for you twice: once for a Telegram bot token, once to
approve a Claude sign-in URL. Safe to re-run if anything is interrupted.

EOF

cd "$REPO_PATH"
# setup.sh prompts for a bot token and a sign-in code. Point its stdin at the
# terminal: this script's stdin may be the pipe it was read from, which would
# feed setup.sh leftover script text instead of the operator's answers. Safe
# here because exec replaces this process, so nothing further is read from it.
exec ./setup.sh run < "$TTY_DEV"
