#!/usr/bin/env bash
# Feature-gate behaviour: optional plugins load only when enabled in config.json.
# Run from repo root: bash tests/feature_gate.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
CONTENT_DIR="$(mktemp -d)"
export REPO_DIR CONTENT_DIR
source lib/common.sh

fail=0
check() { # <desc> <expected 0|1> <actual rc>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want rc=$2 got rc=$3)"; fail=1; fi
}
set_config() { printf '%s' "$1" > "${CONTENT_DIR}/config.json"; CONFIG=""; }

# explicit true / false
set_config '{"features":{"telegram":true,"whatsapp":true}}'
feature_enabled telegram; check "telegram explicitly true -> enabled" 0 $?
feature_enabled whatsapp; check "whatsapp explicitly true -> enabled" 0 $?

set_config '{"features":{"telegram":false,"whatsapp":false}}'
feature_enabled telegram; check "telegram explicitly false -> disabled" 1 $?
feature_enabled whatsapp; check "whatsapp explicitly false -> disabled" 1 $?

# unlisted: everything off except telegram (back-compat for pre-features configs)
set_config '{"features":{}}'
feature_enabled whatsapp; check "whatsapp unlisted -> disabled" 1 $?
feature_enabled telegram; check "telegram unlisted -> enabled (default interface)" 0 $?

set_config '{"git":{"user_name":"x"}}'
feature_enabled whatsapp; check "no features block -> whatsapp disabled" 1 $?
feature_enabled telegram; check "no features block -> telegram still enabled" 0 $?

# an unknown future feature is off unless asked for
set_config '{"features":{}}'
feature_enabled somethingnew; check "unknown feature -> disabled" 1 $?

# core plugins must never be gated
CORE_PLUGINS=" claude_session cron autoupdate "
for p in claude_session cron autoupdate; do
  if [[ "$CORE_PLUGINS" == *" ${p} "* ]]; then echo "ok   core plugin '${p}' bypasses the gate";
  else echo "FAIL core plugin '${p}' not in CORE_PLUGINS"; fail=1; fi
done
# and telegram/whatsapp must NOT be core (they are gated features)
for p in telegram whatsapp; do
  if [[ "$CORE_PLUGINS" != *" ${p} "* ]]; then echo "ok   '${p}' is a gated feature";
  else echo "FAIL '${p}' must not be core"; fail=1; fi
done

rm -rf "$CONTENT_DIR"
[ $fail -eq 0 ] && echo "feature_gate: PASS" || { echo "feature_gate: FAIL"; exit 1; }
