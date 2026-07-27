#!/usr/bin/env bash
# .env handling in lib/paths.sh: precedence is the environment, then .env, then
# the sibling layout; a .env value is data and is never executed; the legacy
# *_DIR names still resolve and say so.
# Run from repo root: bash tests/env_loader.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PATHS_LIB="$(pwd)/lib/paths.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want [$2] got [$3])"; fail=1; fi
}

# resolve <repo-dir> <var> [KEY=VALUE...] - the variable's value on stdout,
# warnings on stderr. One clean shell per case, because env_file_load only
# fills what is still unset and a leaked export would decide the next case.
resolve() {
  local repo="$1" var="$2"; shift 2
  env -i PATH="$PATH" "$@" REPO_PATH="$repo" bash -c '
    source "$0"
    resolve_host_paths || exit 1
    printf "%s" "${!1}"' "$PATHS_LIB" "$var"
}

mkdir -p "${TMP}/plain" "${TMP}/dotenv" "${TMP}/bad"
printf 'CONTENT_PATH=%s/from-dotenv\n' "$TMP" > "${TMP}/dotenv/.env"
printf 'this is not a key=value line\n' > "${TMP}/bad/.env"

# no .env: the sibling-directory layout docker-compose.yml also defaults to
check "no .env falls back to the sibling layout" \
  "${TMP}/zoidberg-config" "$(resolve "${TMP}/plain" CONTENT_PATH)"

check ".env beats the built-in default" \
  "${TMP}/from-dotenv" "$(resolve "${TMP}/dotenv" CONTENT_PATH)"

check "explicit environment beats .env" \
  "${TMP}/from-environment" \
  "$(resolve "${TMP}/dotenv" CONTENT_PATH CONTENT_PATH="${TMP}/from-environment")"

# A legacy name is still read, and the warning names both so a runbook that
# says CONTENT_DIR can be corrected.
legacy_err="${TMP}/legacy.err"
check "legacy CONTENT_DIR still resolves" \
  "${TMP}/legacy-content" \
  "$(resolve "${TMP}/plain" CONTENT_PATH CONTENT_DIR="${TMP}/legacy-content" 2>"$legacy_err")"
if grep -q "CONTENT_DIR is the old name for CONTENT_PATH" "$legacy_err"; then
  echo "ok   legacy CONTENT_DIR warns which name supplied the value"
else
  echo "FAIL legacy CONTENT_DIR warned nothing (stderr: $(cat "$legacy_err"))"; fail=1
fi

# An unparseable line stops the caller rather than being guessed at.
rc=0
resolve "${TMP}/bad" CONTENT_PATH >/dev/null 2>"${TMP}/bad.err" || rc=$?
check "an unparseable .env line fails the resolve" 1 "$rc"
if grep -q "cannot parse line" "${TMP}/bad.err"; then
  echo "ok   the unparseable line is named"
else
  echo "FAIL the unparseable line was not named (stderr: $(cat "${TMP}/bad.err"))"; fail=1
fi

# .env is data, not bash. Sourcing it would run a backtick or a $(...) in a
# path, as root under cron.
mkdir -p "${TMP}/inject"
{
  printf 'ZOIDBERG_SUBST=/tmp/x$(touch %s/pwned-subst)\n' "$TMP"
  printf 'ZOIDBERG_TICK=/tmp/x`touch %s/pwned-tick`\n' "$TMP"
} > "${TMP}/inject/.env"
injected="$(env -i PATH="$PATH" bash -c '
  source "$0"
  env_file_load "$1"
  printf "%s|%s" "$ZOIDBERG_SUBST" "$ZOIDBERG_TICK"' "$PATHS_LIB" "${TMP}/inject/.env")"
check "a \$(...) and a backtick in .env stay literal" \
  "/tmp/x\$(touch ${TMP}/pwned-subst)|/tmp/x\`touch ${TMP}/pwned-tick\`" "$injected"
for marker in pwned-subst pwned-tick; do
  if [ -e "${TMP}/${marker}" ]; then echo "FAIL .env line executed (${marker} created)"; fail=1;
  else echo "ok   .env line was not executed (${marker})"; fi
done

[ $fail -eq 0 ] && echo "env_loader: PASS" || { echo "env_loader: FAIL"; exit 1; }
