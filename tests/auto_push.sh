#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh
source lib/auto-push.sh

fail() { echo "FAIL auto_push: $1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch main

REPO_DIR="$WORK/app"
mkdir -p "$REPO_DIR/logs"
ALERTS="$WORK/alerts"
record_alert() { printf '%s\n' "$1" >> "$ALERTS"; }
NOTIFY_FN=record_alert
AUTO_PUSH_LOCK="$WORK/lock"

new_world() {
  rm -rf "$WORK/origin.git" "$WORK/content" "$WORK/other" "$ALERTS"
  git init -q --bare "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
  printf '__pycache__/\n' > "$WORK/seed/.gitignore"
  printf 'one\n' > "$WORK/seed/note.txt"
  git -C "$WORK/seed" add -A
  git -C "$WORK/seed" commit -q -m seed
  git -C "$WORK/seed" push -q origin main
  rm -rf "$WORK/seed"
  git clone -q "$WORK/origin.git" "$WORK/content"
  git clone -q "$WORK/origin.git" "$WORK/other"
  export CONTENT_DIR="$WORK/content" AUTO_PUSH_REPOS="$WORK/content"
}

origin_file() { git -C "$WORK/origin.git" show "main:$1"; }
origin_count() { git -C "$WORK/origin.git" rev-list --count main; }
alert_count() { if [ -f "$ALERTS" ]; then wc -l < "$ALERTS" | tr -d ' '; else echo 0; fi; }

new_world
printf 'edited\n' > "$WORK/content/note.txt"
mkdir -p "$WORK/content/scripts/__pycache__"
printf 'bytecode\n' > "$WORK/content/scripts/__pycache__/x.pyc"
auto_push
[ "$(origin_file note.txt)" = edited ] || fail "edited config file was not pushed"
git -C "$WORK/origin.git" log -1 --format=%s main | grep -q '^auto: bot update' || fail "commit message"
git -C "$WORK/origin.git" ls-tree -r --name-only main | grep -q pycache && fail "gitignored build artefact was pushed"
[ "$(alert_count)" = 1 ] || fail "want one push notice, got $(alert_count)"
echo "ok edited config file is committed and pushed, gitignored files stay out"

new_world
auto_push
[ "$(origin_count)" = 1 ] || fail "clean tree produced a commit"
[ "$(alert_count)" = 0 ] || fail "clean tree produced a notice"
echo "ok clean tree does nothing"

new_world
printf 'one\nfrom the mac\n' > "$WORK/other/mac.txt"
git -C "$WORK/other" add -A
git -C "$WORK/other" commit -q -m "mac commit"
git -C "$WORK/other" push -q origin main
printf 'edited\n' > "$WORK/content/note.txt"
auto_push
[ "$(origin_file note.txt)" = edited ] || fail "bot edit was rejected after a concurrent origin commit"
[ "$(origin_file mac.txt)" = "$(printf 'one\nfrom the mac')" ] || fail "concurrent origin commit lost"
[ "$(origin_count)" = 3 ] || fail "history is not linear: $(origin_count) commits"
echo "ok concurrent origin commit is rebased onto, not rejected"

new_world
printf 'mac version\n' > "$WORK/other/note.txt"
git -C "$WORK/other" commit -q -am "mac edit"
git -C "$WORK/other" push -q origin main
printf 'bot version\n' > "$WORK/content/note.txt"
auto_push
[ "$(origin_file note.txt)" = "mac version" ] || fail "conflicting bot edit overwrote origin"
[ "$(git -C "$WORK/content" rev-list --count origin/main..HEAD)" = 1 ] || fail "local commit not left in place"
[ ! -e "$WORK/content/.git/rebase-merge" ] || fail "rebase left in progress"
[ "$(alert_count)" = 1 ] || fail "want one alert, got $(alert_count)"
grep -q 'git pull --rebase origin main' "$ALERTS" || fail "alert does not name the command: $(cat "$ALERTS")"
grep -qi 'conflict' "$ALERTS" || fail "alert does not carry the error line: $(cat "$ALERTS")"
echo "ok rebase conflict aborts the rebase, keeps the commit and alerts once"

start_scheduler_stub() {
  : > "$WORK/hup"
  bash -c "trap 'echo hup >> \"$WORK/hup\"' HUP; : > \"$WORK/up\"; while :; do sleep 0.1; done" &
  SCHEDULER_PID=$!
  export SCHEDULER_PID
  until [ -e "$WORK/up" ]; do sleep 0.05; done
}
stop_scheduler_stub() {
  kill "$SCHEDULER_PID"
  wait "$SCHEDULER_PID" 2>/dev/null || true
  rm -f "$WORK/up"
}
hup_count() { sleep 0.3; wc -l < "$WORK/hup" | tr -d ' '; }

push_from_other() {
  mkdir -p "$WORK/other/$(dirname "$1")"
  printf 'from the mac\n' > "$WORK/other/$1"
  git -C "$WORK/other" add -A
  git -C "$WORK/other" commit -q -m "mac commit"
  git -C "$WORK/other" push -q origin main
}

new_world
start_scheduler_stub
push_from_other agents/prompt.txt
printf 'edited\n' > "$WORK/content/note.txt"
auto_push
[ "$(hup_count)" = 1 ] || fail "rebase that pulled an agents/ change sent $(hup_count) SIGHUPs, want 1"
[ "$(origin_file note.txt)" = edited ] || fail "bot edit not pushed after the reload"
stop_scheduler_stub
echo "ok rebase that pulls an agents/ change reloads the scheduler once"

new_world
start_scheduler_stub
push_from_other scripts/task.sh
printf 'edited\n' > "$WORK/content/note.txt"
auto_push
[ "$(hup_count)" = 0 ] || fail "rebase that pulled only scripts/ sent a SIGHUP"
stop_scheduler_stub
echo "ok rebase that pulls no agents/ change sends no SIGHUP"

new_world
start_scheduler_stub
mkdir -p "$WORK/content/agents"
printf 'bot prompt\n' > "$WORK/content/agents/own.txt"
auto_push
[ "$(hup_count)" = 0 ] || fail "bot's own agents/ edit with nothing incoming sent a SIGHUP"
stop_scheduler_stub
echo "ok nothing incoming sends no SIGHUP"

echo "PASS auto_push"
