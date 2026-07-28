#!/usr/bin/env bash
# json_write must never leave a half-written config behind, and must say which
# directory it cannot write rather than blaming jq. Run from repo root:
#   bash tests/json_write.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0

# Exercise the real functions rather than a copy, without running the dispatch.
harness() { # <jq-filter-and-args...> ; reads FILE from $1
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'err(){ printf "[error] %s\n" "$*" >&2; }'
    sed -n '/^sudo_for() {/,/^}/p' "${REPO}/setup.sh"
    sed -n '/^json_write() {/,/^}/p' "${REPO}/setup.sh"
    echo 'f="$1"; shift; json_write "$f" "$@"'
  } > "${TMP}/h.sh"
}
harness

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok $1"; else echo "  FAIL $1: want [$2] got [$3]"; fail=1; fi
}

echo "writable directory, normal write"
mkdir -p "${TMP}/w"
printf '{"telegram":{"bot_token":"old"}}\n' > "${TMP}/w/secrets.json"
chmod 600 "${TMP}/w/secrets.json"
bash "${TMP}/h.sh" "${TMP}/w/secrets.json" --arg t NEW '.telegram.bot_token = $t' >/dev/null 2>&1
check "value replaced" "NEW" "$(jq -r '.telegram.bot_token' "${TMP}/w/secrets.json")"
check "mode preserved" "600" "$(stat -c '%a' "${TMP}/w/secrets.json" 2>/dev/null || stat -f '%A' "${TMP}/w/secrets.json")"
check "no temp left" "secrets.json" "$(ls "${TMP}/w")"

echo "jq failure leaves the original untouched"
set +e
bash "${TMP}/h.sh" "${TMP}/w/secrets.json" '.x | error("boom")' >/dev/null 2>&1
rc=$?
set -e
check "returns non-zero" "1" "$rc"
check "original intact" "NEW" "$(jq -r '.telegram.bot_token' "${TMP}/w/secrets.json")"
check "no temp left" "secrets.json" "$(ls "${TMP}/w")"

echo "unwritable directory with no sudo names the directory"
# install.sh chowns the overlay to 1000:1000, so an operator who is neither
# that uid nor root lands here. Without sudo it must fail loudly, not blame jq.
mkdir -p "${TMP}/ro" "${TMP}/bin"
printf '{"telegram":{}}\n' > "${TMP}/ro/secrets.json"
for b in bash jq tee stat rm mv chmod chown dirname id; do
  p="$(command -v "$b")" && ln -sf "$p" "${TMP}/bin/$b"
done
[ -e "${TMP}/bin/sudo" ] && { echo "  FAIL stub PATH still has sudo"; fail=1; }
chmod 555 "${TMP}/ro"
set +e
out="$(PATH="${TMP}/bin" "${TMP}/bin/bash" "${TMP}/h.sh" "${TMP}/ro/secrets.json" '.a = 1' 2>&1)"
rc=$?
set -e
chmod 755 "${TMP}/ro"
check "returns non-zero" "1" "$rc"
case "$out" in
  *"${TMP}/ro is not writable"*) echo "  ok names the directory" ;;
  *) echo "  FAIL wrong message: $out"; fail=1 ;;
esac
case "$out" in
  *"jq failed"*) echo "  FAIL still blames jq"; fail=1 ;;
  *) echo "  ok does not blame jq" ;;
esac

[ $fail -eq 0 ] && echo "json_write: PASS" || { echo "json_write: FAIL"; exit 1; }
