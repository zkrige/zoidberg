#!/usr/bin/env bash
# The in-container autoupdate plugin pulls on its own schedule and can beat the
# host deploy loop to a commit. When it does, self-update.sh sees HEAD equal to
# origin/main and skips its whole rebuild-or-reload decision, so autoupdate has
# to make the same call itself. This asserts the two classifiers agree.
# Run from repo root: bash tests/autoupdate_class.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

log() { :; }
# shellcheck source=watchers/plugins/autoupdate.sh
source watchers/plugins/autoupdate.sh

check() { # <paths> <expected>
  local got; got="$(_autoupdate_change_class "$1")"
  if [ "$got" = "$2" ]; then echo "  ok ${2}: $(printf '%s' "$1" | tr '\n' ' ')"
  else echo "  FAIL want [$2] got [$got] for: $1"; fail=1; fi
}

echo "classification"
check "Dockerfile" build
check "docker/entrypoint.sh" build
check "docker-compose.yml" build
check "watchers/scheduler.sh" code
check "watchers/plugins/cron.sh" code
check "lib/common.sh" code
check "lib/channels/bot-channel/server.ts" content
check "README.md" content
check "agents/guardrails.txt" content
check "tests/json_write.sh" content
# Build wins: a commit touching both must not reload in a stale image.
check "$(printf 'lib/common.sh\nDockerfile')" build
check "$(printf 'README.md\nwatchers/scheduler.sh')" code

echo "build changes are never pulled in-container"
grep -q 'leaving them to the host deploy loop' watchers/plugins/autoupdate.sh \
  && echo "  ok build class returns before the pull" \
  || { echo "  FAIL build class no longer bails out"; fail=1; }
grep -q 'kill -HUP 1' watchers/plugins/autoupdate.sh \
  && echo "  ok code class reloads the scheduler" \
  || { echo "  FAIL code class no longer reloads"; fail=1; }

[ $fail -eq 0 ] && echo "autoupdate_class: PASS" || { echo "autoupdate_class: FAIL"; exit 1; }
