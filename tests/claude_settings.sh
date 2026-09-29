#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${REPO_DIR}/docker/claude-settings.jq"
fail() { echo "FAIL: $*"; exit 1; }

EXISTING='{"permissions":{"defaultMode":"bypassPermissions"},"model":"haiku","effortLevel":"medium","tui":"fullscreen","hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}'

once=$(printf '%s' "$EXISTING" | jq -f "$FILTER")
twice=$(printf '%s' "$once" | jq -f "$FILTER")
[ "$once" = "$twice" ] || fail "filter is not idempotent across container restarts"

[ "$(jq -r .model <<<"$once")" = "haiku" ] || fail "persisted model was dropped"
[ "$(jq -r '.hooks.Stop | length' <<<"$once")" = "1" ] || fail "other hooks were dropped"
[ "$(jq -r '.hooks.PreModelSwitch | length' <<<"$once")" = "1" ] || fail "expected exactly one PreModelSwitch entry"

hook_cmd=$(jq -r '.hooks.PreModelSwitch[0].hooks[0].command' <<<"$once")
decision=$(bash -c "$hook_cmd" | jq -r '.hookSpecificOutput | select(.hookEventName == "PreModelSwitch") | .permissionDecision')
[ "$decision" = "allow" ] || fail "PreModelSwitch hook does not allow the switch: got '${decision}'"

fresh=$(printf '{}' | jq -f "$FILTER")
[ "$(jq -r .permissions.defaultMode <<<"$fresh")" = "bypassPermissions" ] || fail "fresh settings not in bypass mode"
[ "$(jq -r .tui <<<"$fresh")" = "fullscreen" ] || fail "fresh settings missing pre-seeded tui"

grep -q 'jq -f /app/docker/claude-settings.jq' "${REPO_DIR}/docker/entrypoint.sh" || fail "entrypoint.sh not wired to claude-settings.jq"

echo PASS
