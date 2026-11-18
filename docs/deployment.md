# Deployment
Production is a Docker container (`zoidberg`, scheduler = PID 1) on a Linux
host. The repo is bind-mounted `${REPO_PATH:-.}` → `/app`; the skills repo
`${SKILLS_PATH:-../claude-skills}` → the container's skills dir; the content
repo `${CONTENT_PATH:-../zoidberg-config}` → `/app/config`
(`docker-compose.yml`), with `CONTENT_DIR=/app/config` set in the container
environment. `config/` joins `skills/` as a bind-mounted repo - same pattern,
separate repo. `docker/entrypoint.sh` reads git identity
(`.git.user_name`/`.git.user_email`) from `/app/config/config.json`, and
chowns `/app/config/secrets.json` (the bind-mount may land root-owned). If the
overlay contains a `firebase-tools.json` (a logged-in Firebase CLI
configstore), the entrypoint installs it to `~/.config/configstore/` on every
start; `firebase-tools` needs real CLI login state (gcloud ADC is rejected)
and `~/.config` is container-local, wiped on rebuild. If `npx firebase-tools
mcp` fails with `Invalid Version:` and an empty version, the cause is a
half-written `~/.npm/_npx/<hash>` install: package directories with no
`package.json`, on which Arborist's dedupe throws. Delete that one cache
directory and re-run.

## Host paths and `.env`
Compose's relative defaults resolve against the compose file's directory, so
out of the box the mounts are "this repo, plus its two sibling repos". The real
paths are pinned in `.env` at the repo root, written by `env_write_defaults`
(`lib/paths.sh`) from `install.sh` and `setup.sh env`. It holds `REPO_PATH`,
`CONTENT_PATH`, `SKILLS_PATH`, `COMPOSE_PROJECT_NAME=zoidberg` (unpinned, the
project name would come from the directory basename and namespace the
`claude-home` and `wa-bridge-store` named volumes) and a detected
`SSH_KEY_PATH`. The writer only ever ADDS missing keys; an existing value is
never rewritten. Three optional keys turn on the secret-store mirror (Deployment
step 6): `SECRET_STORE_REPO` (git URL; absent means off), `SECRET_STORE_FILE`
(path inside that repo, default `credentials.enc.json`) and `SECRET_STORE_PATH`
(host clone, default a `zoidberg-secret-store` sibling of the repo).

Host-side names are `*_PATH`; `*_DIR` is the in-container spelling and a
different thing. `REPO_DIR`/`CONTENT_DIR`/`SKILLS_DIR` still work as host-side
input and warn when they are what supplied the value. `install.sh`, `setup.sh`
and `scripts/self-update.sh` all resolve through `resolve_host_paths`, which
reads `.env` by parsing it (never `source`, which would execute it) and sets
only variables that are not already set. `setup.sh verify` asserts every mount
SOURCE against the resolved paths, so a compose fallback shows up as one line
instead of a mystery.

Installing elsewhere is `REPO_PATH=~/zoidberg ./install.sh`; the overlay and
skills default to siblings of it, and no file needs editing.

WhatsApp support is an opt-in build: the Go bridge toolchain, gcc, and the
`docker/whatsapp-bridge-src/`/`docker/whatsapp-mcp-server/` sources are only
built and copied into the image when built with `--build-arg
ENABLE_WHATSAPP=1` (default `0`). The default build never touches those
paths, installs no Go/gcc/uv, and produces no `whatsapp-bridge` binary or
`/opt/whatsapp-mcp-server`; `docker/entrypoint.sh`'s bridge-start and MCP
registration steps are no-ops when the binary/directory are absent.

Voice-note transcription is `transcribe <audio-file>` (`docker/transcribe`),
which resamples to 16kHz mono WAV and prints the transcript to stdout. It wraps
a whisper.cpp `whisper-cli` built from source in the `whisper-payload` stage.
Three build args tune it, all surfaced through `docker-compose.yml` so `.env`
sets them:
- `ENABLE_WHISPER` (default `1`) - `0` swaps in the empty payload stage, so no binary or model reaches the image and `transcribe` exits non-zero with a rebuild hint.
- `WHISPER_MODEL` (default `base`) - any name whisper.cpp's `download-ggml-model.sh` accepts. Bigger is more accurate and slower; `.en` variants are English-only.
- `WHISPER_NATIVE` (default `0`) - `1` compiles `-mcpu=native` against the BUILD host's CPU, worth ~2x. Correct for the normal deploy here (`docker compose up -d --build` runs on the machine that runs the container) and wrong the moment that image moves to a different CPU, where it faults rather than running slowly.

The App Store Connect CLI `asc` is installed at `/usr/local/bin/asc`, pinned by
`ASC_VERSION` (default `6.0.0`) and verified against the release checksums file
during the build, so a mismatch fails the build. The asset is `linux_arm64`, so
the build fails on any other architecture. `ASC_TELEMETRY_DISABLED=1` and
`ASC_CONFIG_PATH=/home/claude/.asc/config.json` are set in the image.

The build also sets `BUILD_SHARED_LIBS=OFF`, so one static binary ships without
libwhisper/libggml beside it. Speed is host-dependent: on the RK3588 reference
box, 8 threads against a 60s clip, `base` takes 16.3s at the defaults and 8.6s
with `WHISPER_NATIVE=1`, against 89s for the openai-whisper package this
replaced. Dropping that package also removed a 639MB torch install (1.1GB of
`dist-packages`), against ~142MB for the default model.

Neither gate saves build time without BuildKit: the classic builder builds
every stage regardless of which one the `FROM ...-${ARG}` line selects, so a
host with no `buildx` (the RK3588 reference box included) still compiles the
disabled payloads. The gates keep the image clean, not the build fast.

Deploy is git-driven via a host cron every 5 minutes (`scripts/self-update.sh`):
1. `git fetch`; if behind, stash local bot edits, `git pull --ff-only`, pop. All three repos go through `sync_repo` (`lib/repo-sync.sh`), which fails loudly: a failed fetch, pull or stash pop, or a repo left with an unmerged path or a `MERGE_HEAD`/`rebase-merge`/`rebase-apply` marker, sends ONE Telegram message naming the repo, the command and the first error line (host-direct through `_tg_send`, using `$CONTENT_PATH/secrets.json`), and the script exits non-zero after still trying the other repos. The last alerted failure is hashed into `state/self-update-alert.<repo>`, so the same broken state does not re-alert every 5 minutes; the first clean sync after it sends one `recovered` message and clears the file. The hash keys on the unresolved git state when there is one, so a stash pop conflict and the next run's unmerged-path check are the same failure. Before 2026-10-30 a pop conflict printed one `WARN` log line, left an unmerged file, and every later run failed with `needs merge` unannounced for 3 days (`tests/self_update_alerts.sh`).
2. Rebuild gate, checked on EVERY run (not only when this script pulled): if `Dockerfile`/`docker/`/`docker-compose.yml` changed since the commit recorded in `state/.deployed-build-commit` (the commit the running image was built from; `deploy_rebuild_needed` in `lib/paths.sh`, `tests/deploy_gate.sh`) → `docker compose up -d --build --force-recreate`, record the new commit, then `docker image prune -f` to drop the 2.27GB image the retag just orphaned (dangling only, never `-a`). Gating on the marker instead of the pull catches commits born in the container's own bind-mounted tree (the bot commits and pushes, so HEAD is already at origin/main when the cron looks). On 2026-08-13 the bot committed a Dockerfile change inside the bind-mounted repo and pushed from there; the old `HEAD != origin/main` gate saw them equal and never rebuilt, so the change sat unbuilt for an hour while the bot reported "still building" (commits 3758340, 5525781). The marker is seeded from the PRE-pull commit, and a marker sha the repo does not recognise forces a conservative rebuild. `scripts/self-update.sh` takes a `flock` singleton because the marker only lands after the build finishes, so overlapping 5-minute ticks would otherwise double-build. A quiet, up-to-date run logs NOTHING, so an idle log is normal rather than a stalled cron.
3. Elif this run pulled and `watchers/`, `lib/*.sh` or `lib/channels/` changed → `docker kill --signal=HUP zoidberg`. (`lib/channels/` counts because the bot-channel MCP server is launched by the session: without a respawn the new file is on disk and the old server keeps running.) The SIGHUP re-execs the scheduler, which runs every plugin `_cleanup` (killing the tmux session) then re-inits and respawns the session with its new launch args and clean context.
4. Else (agents/scripts/docs) → no reload; those are read fresh at dispatch.
5. It also syncs the skills repo and the content repo (`sync_repo` again: fetch, stash-pull-pop if the mount has local edits, run `setup.sh` if present) and runs their setup scripts. A content pull that touched `agents/` also SIGHUPs: the session system prompt is assembled at spawn from the framework prompts plus `config/agents/*.local.txt`, so a prompt edit is invisible to the running session until it respawns. Task prompts and `config/scripts/` are read fresh at dispatch and trigger nothing.
6. Secret store, when `SECRET_STORE_REPO` is set in `.env`: sparse-mirror that git repo into `SECRET_STORE_PATH` (only `SECRET_STORE_FILE`, default `credentials.enc.json`, is checked out; `secret_store_mirror` in `lib/paths.sh`). When the mirrored ciphertext differs from `store/volume-backup/credentials.enc.json` (`secret_store_changed`) it is copied there (mode 600, uid 1000) and `docker exec zoidberg bash /app/docker/sync-secret-store.sh` decrypts it in place. No respawn: scheduled tasks and skills read the plaintext with `jq` at call time. The store is SOPS + age ciphertext, so a private repo can hold it; the container decrypts with the age key `docker-compose.yml` mounts at `/run/age-key.txt`. Rotating a credential is therefore: edit the store, commit, push; the host applies it within 5 minutes. `tests/secret_store_sync.sh` covers the mirror and change detection, `tests/secret_store_decrypt.sh` the in-container script (skips without `sops` and `age-keygen`).

So a `git push` to `main` is the entire deploy - the host applies it within 5
minutes. The bot also auto-pushes its own changes; `autoupdate.sh` is an
in-container backstop, not the primary mechanism.

`auto_push` (`lib/auto-push.sh`) commits (`auto: bot update (<diffstat>)`) and pushes what Claude left in `/app`, the skills repo and the content repo (`CONTENT_DIR`). It runs when a Telegram turn finalizes (`_telegram_run_finalize`), when `bot_channel_wait_reply` returns a reply (which covers scheduled prompt tasks, WhatsApp triage, self-evolve and `/retry`), and from `autoupdate_tick` every 5 minutes as the catch-all. One `flock` (`AUTO_PUSH_LOCK`) serialises the callers. For the content repo only, `git pull --rebase origin main` runs between commit and push so a commit made elsewhere in the meantime does not reject the push; a rebase conflict runs `git rebase --abort`, keeps the local commit and sends a Telegram alert in the same `<repo> failed: <command>: <first error line>` shape as self-update. A tree dirtied by an untracked build artefact is the content repo's `.gitignore` to handle (`__pycache__/`). A pull that `auto_push` makes inside the container leaves the host's `self-update.sh` nothing to pull, so when the rebase brings in commits touching `agents/` (`content_prompts_changed`, the same check `self-update.sh` uses) `auto_push` sends the SIGHUP itself, to `SCHEDULER_PID` (default 1). `tests/auto_push.sh` covers push, ignored files, a concurrent origin commit, a rebase conflict, and the reload with and without incoming `agents/` changes.

The two race harmlessly for build changes now (the marker gate fires no matter
who pulled), but `autoupdate.sh` still classifies the incoming range with the
same two patterns (`_autoupdate_change_class`) and acts on it: build changes
are NOT pulled at all (no docker CLI or socket in the container),
`watchers/`/`lib/*.sh`/`lib/channels/` changes are pulled and followed by `kill -HUP 1`, and
everything else is pulled and left alone. The patterns must stay identical to
the host's; `tests/autoupdate_class.sh` asserts the classification.

Every remote git call the scheduler makes in its own loop (autoupdate's fetch,
pull and push, and `auto_push`) goes through `git_remote`
(`lib/common.sh`), which kills it, ssh child included, after
`GIT_REMOTE_TIMEOUT` (120s). On 2026-10-20 an unbounded `git fetch` hung on
its ssh to the remote for 1h42m. PID 1 runs one loop, so Telegram polling
stopped with it, and a `/login` sent while the session's OAuth had expired
was never read. `tests/git_remote_timeout.sh` covers plain and captured output.

`scripts/scheduled-restart.sh` (host cron, daily) restarts the container to
reset tmux, auth and session state.

It will not land mid-dispatch. Two kinds of marker say a dispatch is open, and
`state/` is inside the bind-mounted repo so the host reads both directly:
`lib/telegram-run.sh` writes `state/telegram-in-progress.json` before
dispatching and removes it when the turn finalizes, and `cron.sh`'s
`_cron_post` writes `state/.<task>.inflight` per dispatched task (several can
be open at once) and clears it when the reply lands. While ANY of them is
present the script polls every `RESTART_WAIT_INTERVAL` (10s) for up to
`RESTART_WAIT_MAX` (1200s, telegram.sh's and cron.sh's `CLAUDE_WALL_TIMEOUT`);
if one is still there at the cap it SKIPS the day rather than restarting, and
logs which turn or task blocked it. A restart on top of a live Telegram turn
kills the session mid-answer and `_telegram_recover_crash` then replays the raw
message into the respawned session (which resumes prior context via
`--continue` but has lost the in-flight partial answer); a killed cron
dispatch leaves its lock behind and loses the run's output. A marker older than
`RESTART_MARKER_STALE` (1800s, past the wall timeout and the same threshold as
cron.sh's own `INFLIGHT_STALE`) has leaked and is ignored, so a stuck file
cannot disable the restart forever. A missing `state/` directory is a
misconfiguration: the script logs it and exits 1 without restarting.
`tests/restart_inflight.sh` covers all nine cases.

## /reload vs /restart
- `/reload` (`kill -HUP 1`): scheduler re-execs, re-sources plugin code, and respawns the session (cleanup kills it, init relaunches with current args). Applies code already on disk. This is what `scripts/self-update.sh` triggers for `watchers/`/`lib` changes.
- `/restart` (`kill -TERM 1`): PID 1 exits and Docker recreates the container. Full reset.
