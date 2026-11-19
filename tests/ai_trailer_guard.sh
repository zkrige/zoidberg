#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="${REPO_DIR}/docker/git-hooks"
fail() { echo "FAIL: $*"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

export HOME="${work}/home"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global core.hooksPath "$HOOKS"
git config --global init.defaultBranch main

TRAILERS=$'\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_abc\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)'
HUMAN_TRAILER="Co-Authored-By: Jane Doe <jane@example.com>"

git init -q --bare "${work}/remote.git"
git clone -q "${work}/remote.git" "${work}/repo" 2>/dev/null
cd "${work}/repo"
echo a > a.txt && git add a.txt

git commit -q -m "fix thing${TRAILERS}"
msg="$(git log -1 --format=%B)"
echo "$msg" | grep -qiE 'Claude|anthropic' && fail "commit-msg left an AI line: ${msg}"
[ "$(git log -1 --format=%s)" = "fix thing" ] || fail "subject changed"

echo b > b.txt && git add b.txt
git commit -q -m "keep human trailer

${HUMAN_TRAILER}"
git log -1 --format=%B | grep -q "$HUMAN_TRAILER" || fail "human Co-Authored-By was removed"

echo c > c.txt && git add c.txt
git commit -q --amend -m "amended${TRAILERS}"
git log -1 --format=%B | grep -qiE 'Claude|anthropic' && fail "amend left an AI line"

git push -q origin HEAD:main 2>/dev/null || fail "clean push was refused"

echo d > d.txt && git add d.txt
git commit -q --no-verify -m "bypass${TRAILERS}"
git log -1 --format=%B | grep -q 'Claude-Session' || fail "test setup: --no-verify commit should keep trailers"
if git push -q origin HEAD:main 2>"${work}/push.err"; then fail "pre-push allowed a commit with AI attribution"; fi
grep -q "refusing to push" "${work}/push.err" || fail "pre-push refused without its message"
git commit -q --amend --no-edit
git log -1 --format=%B | grep -q 'Claude-Session' && fail "amend --no-edit kept trailers"
git push -q origin HEAD:main 2>/dev/null || fail "push after cleaning was refused"

echo e > e.txt && git add e.txt
git commit -q --no-verify -m "new branch${TRAILERS}"
if git push -q origin HEAD:newbranch 2>/dev/null; then fail "pre-push allowed a new branch with AI attribution"; fi

mkdir -p .husky
printf '#!/usr/bin/env bash\ntouch "%s/husky-ran"\n' "$work" > .husky/commit-msg
chmod +x .husky/commit-msg
git config --local core.hooksPath .husky
git reset -q --hard HEAD~1
echo f > f.txt && git add f.txt
git commit -q -m "husky repo${TRAILERS}"
git log -1 --format=%B | grep -q 'Claude-Session' || fail "test setup: local core.hooksPath should bypass the global hooks"

git reset -q --soft HEAD~1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
git commit -q -m "husky repo${TRAILERS}"
git log -1 --format=%B | grep -qiE 'Claude|anthropic' && fail "env override did not beat the repo's core.hooksPath"
[ -f "${work}/husky-ran" ] || fail "repo's own commit-msg hook was not chained"

echo PASS
