#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL self_update_alerts: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch main
git config --global safe.directory '*'

BIN="$WORK/bin"
SENT="$WORK/sent"
mkdir -p "$BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nprintf "{\\"ok\\":true}"\n' "$SENT" > "$BIN/curl"
printf '#!/bin/sh\nexit 0\n' > "$BIN/docker"
chmod +x "$BIN/curl" "$BIN/docker"
export PATH="$BIN:$PATH"

make_repo() {
  local name="$1"
  git init -q --bare "$WORK/origin-$name.git"
  git clone -q "$WORK/origin-$name.git" "$WORK/$name" 2>/dev/null
  printf 'state/\nlogs/\nsecrets.json\n' > "$WORK/$name/.gitignore"
  printf 'one\n' > "$WORK/$name/note.txt"
}

publish() {
  git -C "$WORK/$1" add -A
  git -C "$WORK/$1" commit -q -m "$2"
  git -C "$WORK/$1" push -q origin main
}

advance_origin() {
  git clone -q "$WORK/origin-$1.git" "$WORK/pusher" 2>/dev/null
  printf '%s\n' "$3" > "$WORK/pusher/$2"
  git -C "$WORK/pusher" add -A
  git -C "$WORK/pusher" commit -q -m "advance $2"
  git -C "$WORK/pusher" push -q origin main
  rm -rf "$WORK/pusher"
}

make_repo zoidberg
mkdir -p "$WORK/zoidberg/scripts" "$WORK/zoidberg/lib" "$WORK/zoidberg/state"
cp "$SRC/scripts/self-update.sh" "$WORK/zoidberg/scripts/"
cp "$SRC"/lib/{paths,repo-sync,git-failure,setup-telegram}.sh "$WORK/zoidberg/lib/"
publish zoidberg "install updater"
make_repo claude-skills
printf '#!/bin/bash\nexit 0\n' > "$WORK/claude-skills/setup.sh"
publish claude-skills "seed"
make_repo zoidberg-config
publish zoidberg-config "seed"
printf '{"telegram":{"bot_token":"t","chat_id":"1"}}' > "$WORK/zoidberg-config/secrets.json"

run_update() {
  local rc=0
  "$WORK/zoidberg/scripts/self-update.sh" > "$WORK/run.log" 2>&1 || rc=$?
  return $rc
}
sent_count() { if [ -f "$SENT" ]; then wc -l < "$SENT" | tr -d ' '; else echo 0; fi; }

run_update || fail "clean run exited non-zero: $(cat "$WORK/run.log")"
[ "$(sent_count)" = 0 ] || fail "clean run sent an alert"
echo "ok clean run exits zero and stays quiet"

printf 'local edit\n' > "$WORK/zoidberg-config/note.txt"
advance_origin zoidberg-config note.txt "remote edit"
rc=0; run_update || rc=$?
[ "$rc" != 0 ] || fail "stash pop conflict exited zero"
[ "$(sent_count)" = 1 ] || fail "stash pop conflict: want one alert, got $(sent_count)"
grep -q 'zoidberg-config' "$SENT" || fail "alert does not name the repo: $(cat "$SENT")"
grep -q 'git stash pop' "$SENT" || fail "alert does not name the command: $(cat "$SENT")"
grep -qi 'conflict' "$SENT" || fail "alert does not carry the first error line: $(cat "$SENT")"
echo "ok stash pop conflict sends one alert and exits non-zero"

rc=0; run_update || rc=$?
[ "$rc" != 0 ] || fail "unresolved repo exited zero"
[ "$(sent_count)" = 1 ] || fail "same broken state alerted again: $(sent_count) alerts"
echo "ok the same broken state does not alert twice"

git -C "$WORK/zoidberg-config" reset -q --hard
git -C "$WORK/zoidberg-config" stash drop -q
run_update || fail "recovered repo exited non-zero: $(cat "$WORK/run.log")"
[ "$(sent_count)" = 2 ] || fail "recovery: want one recovery alert, got $(( $(sent_count) - 1 ))"
tail -1 "$SENT" | grep -q 'recovered' || fail "last alert is not a recovery: $(tail -1 "$SENT")"
run_update || fail "post-recovery run failed"
[ "$(sent_count)" = 2 ] || fail "recovery alerted twice"
echo "ok recovery sends one recovery alert"

git -C "$WORK/claude-skills" pull -q --ff-only origin main
printf 'diverged\n' > "$WORK/claude-skills/note.txt"
git -C "$WORK/claude-skills" commit -q -am "local only"
advance_origin claude-skills other.txt "remote"
before=$(sent_count)
rc=0; run_update || rc=$?
[ "$rc" != 0 ] || fail "failed pull exited zero"
[ "$(( $(sent_count) - before ))" = 1 ] || fail "failed pull: want one alert"
tail -1 "$SENT" | grep -q 'claude-skills.*git pull --ff-only origin main' || fail "pull alert text: $(tail -1 "$SENT")"
rc=0; run_update || rc=$?
[ "$(( $(sent_count) - before ))" = 1 ] || fail "failed pull alerted again"
echo "ok a failed pull in another repo alerts once"

echo "PASS self_update_alerts"
