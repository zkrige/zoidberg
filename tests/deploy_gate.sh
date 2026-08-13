#!/usr/bin/env bash
# deploy_rebuild_needed: the host deploy loop must rebuild when build files
# changed since the commit the running image was BUILT from, not since the
# last pull. A commit born in the Pi's own tree (the bot committing in the
# bind-mounted repo, then pushing) leaves HEAD == origin/main, so the old
# "HEAD != origin/main" gate skipped the rebuild forever (2026-08-13:
# Playwright Dockerfile change sat unbuilt for an hour).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_DIR}/lib/paths.sh"

fail() { echo "FAIL deploy_gate: $1"; exit 1; }

WORK="/tmp/deploygate-$$"
mkdir -p "$WORK/repo"
MARKER="$WORK/marker"
cd "$WORK/repo"
git init -q
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
echo a > Dockerfile && git add Dockerfile
git -c user.name=t -c user.email=t@t commit -q -m c1
C1=$(git rev-parse HEAD)
echo b > README.md && git add README.md
git -c user.name=t -c user.email=t@t commit -q -m c2
C2=$(git rev-parse HEAD)
mkdir -p docker && echo c > docker/x && git add docker/x
git -c user.name=t -c user.email=t@t commit -q -m c3
C3=$(git rev-parse HEAD)

# 1. Marker missing: bootstrap to HEAD, no rebuild.
deploy_rebuild_needed "$WORK/repo" "$MARKER" && fail "missing marker triggered rebuild"
[ "$(cat "$MARKER")" = "$C3" ] || fail "marker not bootstrapped to HEAD"

# 2. Marker == HEAD: no rebuild.
deploy_rebuild_needed "$WORK/repo" "$MARKER" && fail "up-to-date marker triggered rebuild"

# 3. Marker at c1, HEAD c2 only in range... simulate: non-build change since marker.
printf '%s\n' "$C2" > "$MARKER"
git checkout -q "$C2"
deploy_rebuild_needed "$WORK/repo" "$MARKER" && fail "no-change range triggered rebuild"
printf '%s\n' "$C1" > "$MARKER"
deploy_rebuild_needed "$WORK/repo" "$MARKER" && fail "README-only range triggered rebuild"

# 4. Build file changed since marker: rebuild.
git checkout -q "$C3"
printf '%s\n' "$C1" > "$MARKER"
deploy_rebuild_needed "$WORK/repo" "$MARKER" || fail "docker/ change since marker missed"
printf '%s\n' "$C2" > "$MARKER"
deploy_rebuild_needed "$WORK/repo" "$MARKER" || fail "docker/ change (c2..c3) missed"

# 5. Unknown marker sha: conservative rebuild.
echo 0123456789abcdef0123456789abcdef01234567 > "$MARKER"
deploy_rebuild_needed "$WORK/repo" "$MARKER" || fail "unknown marker sha did not rebuild"

# 6. deploy_mark_built records HEAD.
deploy_mark_built "$WORK/repo" "$MARKER"
[ "$(cat "$MARKER")" = "$C3" ] || fail "deploy_mark_built wrong sha"

# 7. Wiring: self-update.sh uses the gate and the marker, and seeds the
# marker from the PRE-pull commit so a missing marker can't swallow build
# changes arriving in the same run's pull.
grep -q 'deploy_rebuild_needed' "${REPO_DIR}/scripts/self-update.sh" || fail "self-update.sh not wired to deploy_rebuild_needed"
grep -q 'deploy_mark_built' "${REPO_DIR}/scripts/self-update.sh" || fail "self-update.sh not wired to deploy_mark_built"
grep -q '"\$LOCAL" > "\$BUILD_MARKER"' "${REPO_DIR}/scripts/self-update.sh" || fail "self-update.sh does not seed marker from pre-pull commit"
# The marker is written only when a build FINISHES, so overlapping cron ticks
# during a long build would each start their own build without a singleton.
grep -q 'flock' "${REPO_DIR}/scripts/self-update.sh" || fail "self-update.sh has no singleton lock"

rm -rf "$WORK"
echo PASS
