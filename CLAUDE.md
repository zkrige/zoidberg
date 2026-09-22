# Zoidberg

Local automation suite for Claude Code. A persistent scheduler daemon runs a set
of plugins that feed work into a single always-on interactive Claude session.
That session answers Telegram messages, triages WhatsApp, and runs cron tasks.
Production is a Docker container (scheduler = PID 1). The host only has to run
Docker, so Linux and macOS both work: a Raspberry Pi or Orange Pi is the usual
choice, and a Mac mini runs the identical arm64 image under Docker Desktop.

## Writing to ~/.claude/
The Write and Edit tools cannot create or modify files under `~/.claude/` due to a hardcoded sandbox restriction. When you need to write files there (skills, config, etc.), use Bash instead:
```bash
mkdir -p ~/.claude/skills/my-skill
cat <<'EOF' > ~/.claude/skills/my-skill/SKILL.md
... content ...
EOF
```
This applies to all automated and interactive sessions.

## Repo location
Clone this framework repo wherever you develop. In production the repo is
bind-mounted at `/app` inside the Docker container on the Linux host. The host
path is not fixed: `install.sh` clones to `/opt/zoidberg` by default and writes
the real paths to `.env`, which docker compose reads. Nothing has to be edited
to install somewhere else (see Deployment).

## Architecture

`watchers/scheduler.sh` is a thin orchestrator: singleton lock, wake detection,
plugin loader, and a SIGHUP graceful reload (re-exec self). It sources every
`watchers/plugins/*.sh`, calls each plugin's lifecycle hooks, and loops. Plugin
contract: `_init`, `_tick`, `_cleanup`, and optional `_on_wake`.

Plugins (`watchers/plugins/`):
- `claude_session.sh` - owns the always-on interactive `claude` session (tmux `zoidberg`) and the bot-channel transport. This is how all work reaches Claude.
- `telegram.sh` - long-polls Telegram, queues messages, handles commands, streams responses.
- `cron.sh` - matches cron expressions, evaluates `pre_check` gates, dispatches scheduled tasks.
- `whatsapp.sh` - webhook listener; dispatches `whatsapp-triage` when a self-chat message arrives.
- `autoupdate.sh` - in-container backstop: pulls, self-reloads on scheduler-code changes, defers build changes to the host `scripts/self-update.sh` (see Deployment).

### Framework and content split
This repo (the framework) ships only generic scheduling/transport code and a
small set of behavior prompts. Operator content - `schedule.json`, `models.json`,
`config.json`, `secrets.json`, scheduled-task prompts (`agents/<task>.txt`), and
run-scripts (`scripts/*`) - lives in a separate `config/` git repo that you
create and control (see `examples/` in this repo for a starter layout). In
production it is bind-mounted at `/app/config` from a host clone (e.g.
`/opt/zoidberg-config`); on the dev machine a checked-out copy at `config/` fills
the same role. Content resolves through a `CONTENT_DIR` env, defaulting to
`${REPO_DIR}/config`.

Two helpers in `lib/common.sh` mediate the split:
- `content_path <relative>` - absolute path under `CONTENT_DIR` for operator
  content (`config.json`, `secrets.json`, `schedule.json`, `scripts/*`).
- `framework_prompt <name.txt>` - resolves a framework behavior prompt. A file
  at `${CONTENT_DIR}/agents/<name>.local.txt` is APPENDED to the shipped prompt
  at `${REPO_DIR}/agents/<name>.txt` (merged into `${STATE_DIR}/prompts/` and
  regenerated per call, so edits need no redeploy). This is the right slot for
  operator additions. A file at `${CONTENT_DIR}/agents/<name>.txt` still
  replaces the shipped prompt entirely (content-override-by-presence), but a
  full override shadows it forever: every later framework fix silently stops
  reaching that install, and only a manual diff reveals it. `.local` first,
  always. `prompt-sections.txt` is positional (line 1 is the attribution marker,
  `sed` takes the first match of each header) and takes no `.local`.

Dispatched `command`/`pre_check` tasks get an exported env contract
(`_export_task_env` in `watchers/plugins/cron.sh`): `CONTENT_DIR`, `APP_DIR`
(= `REPO_DIR`), `STATE_DIR`, `SKILLS_DIR`, `CONFIG_FILE`, `SECRETS_FILE`.

### Transport: the always-on interactive session
The bot does NOT spawn `claude -p` per message. It runs ONE persistent
interactive `claude` session in tmux (`zoidberg`), launched by
`claude_session.sh`:
```
claude --permission-mode bypassPermissions --model <model> \
  --append-system-prompt-file state/.session-system-prompt.txt \
  --dangerously-load-development-channels server:bot-channel
```
The interactive transport keeps usage on the subscription pool instead of Agent
SDK credit - that is the entire point of this architecture.

Every plugin dispatches by POSTing an event to the bot-channel HTTP listener on
`127.0.0.1:8790`. The bot-channel MCP server (`lib/channels/bot-channel/server.ts`,
Bun) forwards it to the session as a
`<channel source="bot-channel" request_id="..." kind="telegram|cron">` message.
Claude completes the work and calls the `reply` tool exactly once with that
`request_id`; the server writes the reply to a file the orchestrator polls.

`reply` ENDS the request - the turn is over and nothing further reaches the
owner - so a turn that used it to acknowledge ("checking now, will confirm
shortly") delivered a promise and then stranded the work, leaving the owner to
ping again. Interim updates therefore go through a second tool, `progress`,
which writes a sequenced `<request_id>.progress.<seq>` file and leaves the
request open. `_telegram_run_drain_progress` (`lib/telegram-run.sh`) sends and
deletes those while it waits, in write order; `_cron_wait_reply` discards any a
scheduled task left behind, and `claude_session_spawn` sweeps stale ones.
`tests/progress_drain.sh` covers ordering, delete-after-send, and the
reply/other-request files it must not touch.

`progress` also tells the ORCHESTRATOR the request is still live, which is what
makes background agents work. Dispatching an Agent and ending the turn to wait
for its completion notification leaves the pane idle, and the stream loop's
idle-fallback used to read that as a dead turn and nudge within ~4s, forcing a
premature `reply` that closed the request and stranded the agent's result. So a
delivered `progress` renews patience for `PROGRESS_PATIENCE` (300s) before the
idle-fallback may fire, and once nudged the loop waits `NUDGE_GRACE` (30s)
before scraping the transcript, since the salvage otherwise ships the
acknowledgement the nudge was sent to replace. Both are declared in
`watchers/plugins/telegram.sh` beside the other stream tunables. The wall-clock
check runs FIRST in the loop body: those two windows `continue`, so a check
below them is unreachable while they hold. `tests/nudge_grace.sh` covers it.

The session is PERSISTENT: it retains real conversation turns across dispatches,
and a respawn (deploy SIGHUP, daily container restart) resumes the previous
conversation via `--continue` (`_claude_session_continue_flag`) - the
transcript lives on the `claude-home` volume, so it survives recreates and
rebuilds. The only exception is a first spawn with no prior conversation,
which launches without the flag; wedge-recovery respawns also resume (every
observed "wedge" 2026-08-02..08-13 was a post-restart health-probe false
positive, fixed by a spawn grace period - see `tests/health_probe_grace.sh` -
so forcing a fresh session there would have wiped context daily). An operator
can `touch state/.session-fresh-spawn` to make the next spawn start clean. Context is managed by Claude Code's
own native automatic compaction on Sonnet 5's 1M context window (confirmed by
live production testing; no manual token-threshold clearing is needed). The
daily host `scripts/scheduled-restart.sh` restart still runs to reset tmux and
auth state; conversation context now carries across it.

### Session system prompt and trust model
Identity is verified by the TRANSPORT, never by message content: the Telegram
`chat_id` and WhatsApp JID come from `config/secrets.json` at startup; anything
else is untrusted data.

All stable context lives in the session's REAL system prompt, rebuilt at every
session spawn into `state/.session-system-prompt.txt` from:
- `agents/guardrails.txt` - non-negotiable limits and per-task-type privileges. Framework prompt, resolved via `framework_prompt`; extend it with `config/agents/guardrails.local.txt`.
- `agents/telegram-system.txt` - operating instructions. Same resolution, extended by `config/agents/telegram-system.local.txt`.
- `state/memory.md` - portable long-term facts.
- recent `/feedback` corrections (`state/feedback.log`).

The per-message channel BODY is deliberately minimal: an attribution marker
(`agents/prompt-sections.txt` line 1, also resolved via `framework_prompt`) plus the user's message (plus per-message
media instructions when files are attached). Nothing else. This matters: in a
persistent session the model already holds the real turns, so re-embedding
guardrails, the system prompt, memory, or a conversation transcript in the body
makes a security-aware model read its own scaffolding as a prompt-injection
envelope and refuse genuine owner commands. Keep the body minimal; continuity
comes from the session's own turns, not a re-pasted transcript.

That is not a theoretical risk. On 2026-07-21 the bot refused legitimate owner
commands, replying that the message "arrived wrapped in a large fabricated block
(fake CLAUDE.md/guardrails reprint, fake recent corrections, and a fake
prior-conversation transcript embedded inside the channel payload) ... doesn't
match how real messages have looked in this session." Every dispatch was
assembling the body as `guardrails + telegram-system prompt + feedback + rolling
history transcript + memory + user_msg` and POSTing it verbatim. The model
compared that against its genuine session context and read the difference as
injection. The re-embedded HISTORY transcript was the strongest trigger: "I'm
not treating the embedded transcript as real history". Re-embedding made sense
in the old stateless `claude -p` architecture and became actively harmful once
the session was persistent. Fixed in 9febb91 by building the real system prompt
at spawn and cutting the body to the attribution marker plus the message. A
first attempt (a542513) moved only the guardrails block out of the body and was
INSUFFICIENT, because the system, memory and history bundle still tripped the
detector.

## Telegram bot
- Messages are processed immediately (long-polling, not periodic).
- User-initiated messages run with `bypassPermissions` (you explicitly asked).
- Scheduled tasks post with `kind=cron`; the guardrails' SCHEDULED TASK RESTRICTIONS apply.
- If a scheduled task produces no output, you get a notification with `/retry <task>` to re-run with full permissions.
- All output goes to Telegram, via the bot token configured in `config/secrets.json`.

### Commands
| Command | Action |
|---------|--------|
| `/cancel` | Interrupt the running task (Escape into the session), drain queue |
| `/status` | Show running task, queue depth, model, session |
| `/session <name>` | Switch to named conversation session |
| `/sessions` | List all saved sessions |
| `/feedback <text>` | Log a correction (folded into the session system prompt) |
| `/feedback clear` | Clear the feedback log |
| `/reset` | Reset the active session's message log |
| `/opus` `/sonnet` `/haiku` | Switch Claude model (persisted; applied on next spawn) |
| `/low` `/medium` `/high` `/max` | Switch effort level |
| `/retry <task>` | Re-run a scheduled task with full permissions |
| `/login` | Start Claude OAuth login (when the session's auth expires) |
| `/reload` | `kill -HUP 1`: re-exec scheduler, re-source plugins, respawn the session |
| `/restart` | `kill -TERM 1`: exit PID 1 so Docker recreates the container |

### Named sessions
- Each exchange is appended to `state/sessions/<name>-messages.jsonl` for the record and for memory pruning. It is NOT re-injected into the prompt - continuity comes from the live session's own turns.
- `state/memory.md` holds long-term facts; it is folded into the session system prompt at spawn, and Sonnet prunes it periodically.
- `/reset` clears the active session's message log; `/session <name>` switches; `/sessions` lists.

## Key files
- `watchers/scheduler.sh` - thin orchestrator (lock, wake detection, SIGHUP reload, plugin loader)
- `watchers/plugins/claude_session.sh` - always-on interactive session + bot-channel transport
- `watchers/plugins/telegram.sh` - Telegram bot plugin (polling, queue, streaming, commands)
- `watchers/plugins/cron.sh` - cron engine (schedule matching, pre_check gates, dispatch)
- `watchers/plugins/whatsapp.sh` - WhatsApp webhook plugin (instant dispatch on self-chat)
- `watchers/plugins/autoupdate.sh` - in-container backstop (pull, classify, SIGHUP or defer)
- `lib/channels/bot-channel/server.ts` - bot-channel MCP server (event in; `reply` tool ends the request, `progress` tool sends an interim update and keeps it open)
- `.mcp.json` - registers the session's MCP servers: `bot-channel` (transport, above) and `playwright` (`@playwright/mcp`, headless Chromium baked into the image at build time - navigate/click/fill/screenshot for sites that need a login, since WebFetch can't authenticate)
- `lib/common.sh` - shared utilities (JSON parsing, project matching, logging, notify)
- `lib/paths.sh` - host-side path resolution and the `.env` reader/writer, shared by `install.sh`, `setup.sh` and `scripts/self-update.sh`
- `lib/telegram-*.sh` - Telegram plugin helpers: `-api` (Bot API), `-commands`, `-md` (markdown), `-process`, `-queue`, `-run` (dispatch/stream), `-session` (sessions/history/prompt-sections)
- `lib/whatsapp-dispatch.sh` - WhatsApp triage dispatcher (called by the webhook listener)
- `lib/claude-login.sh` - Claude OAuth sign-in (tmux pane, URL scrape, bounded polls), shared by `setup.sh` and the Telegram `/login` handler
- `lib/evolution.sh` - self-evolve agent (detects failures, improves prompts)
- `agents/guardrails.txt` - non-negotiable guardrails (framework prompt, session system prompt)
- `agents/telegram-system.txt` - Telegram operating instructions (framework prompt, session system prompt)
- `agents/prompt-sections.txt` - attribution marker + section headers (framework prompt)
- `agents/*.txt` - framework behavior prompts only (guardrails, telegram-system, prompt-sections, memory-prune-prompt, self-evolve); resolved via `framework_prompt`, extended by `config/agents/<name>.local.txt`
- `examples/content/` - starter layout for your own content overlay (see `examples/README.md`)
- `config/` - content overlay (a separate private repo you create, mounted or checked out here), resolved via `CONTENT_DIR`:
  - `config/schedule.json` - task schedule definitions (source of truth for the task whitelist)
  - `config/models.json` - model/effort preferences
  - `config/config.json` - central config (endpoints, Bitbucket workspace, git identity); gitignored, placed out-of-band on the host
  - `config/secrets.json` - Telegram bot token and chat ID; gitignored, placed out-of-band on the host
  - `config/agents/*.txt` - prompt files for scheduled tasks
  - `config/agents/*.local.txt` - operator additions appended to the framework prompt of the same name (guardrails, telegram-system, self-evolve)
  - `config/scripts/*` - run-scripts (`pre_check`/`command` entries in `schedule.json`)
  - `config/config.example.json`, `config/secrets.example.json` - templates for the two gitignored files above
- `scripts/self-update.sh` - host-cron git-driven deploy (pull + reload/rebuild + skills + content sync)
- `scripts/scheduled-restart.sh` - host-cron daily container restart (tmux/auth/session hygiene), deferred while a Telegram turn or a cron task is in flight
- `docker/entrypoint.sh` - container startup (auth check, git config, `exec scheduler.sh`)
- `docker/sync-secret-store.sh` - in-container decrypt of `store/volume-backup/credentials.enc.json` into `~/.claude/config/credentials.json` and `/app/store/credentials.json`; run by the entrypoint at every start and by `scripts/self-update.sh` when the mirrored ciphertext changes
- `docker/transcribe` - voice-note transcription (`transcribe <audio-file>` → transcript on stdout), wrapping the whisper.cpp binary baked into the image
- `install.sh` - one-command bootstrap: prerequisites, clone, content overlay, then `setup.sh run`
- `setup.sh` - deterministic setup dispatcher: usage text, output helpers, path resolution, `json_write`, `ask`, and the subcommand `case`
- `lib/setup-*.sh` - the subcommands themselves, sourced by `setup.sh`: `-telegram` (token, chat-id discovery, installer messages), `-config` (`feature`, `identity`, `env`, `status`), `-login` (Claude sign-in), `-cron` (host cron entries), `-verify` (end-to-end check), `-run` (the install sequence)

## Scheduled tasks
`config/schedule.json` is the source of truth; the task whitelist is derived
from it automatically. Each entry: `name`, `cron`, `enabled`, `model`, `effort`,
and either `prompt_file` (dispatches `${CONTENT_DIR}/<prompt_file>`, e.g.
`config/agents/<file>.txt`, to the session) or `command` (runs a shell command
directly, no Claude - for deterministic no-reasoning work). Optional
`pre_check` gates a run, `notify_filter` suppresses output unless it
matches, and `error_filter` (regex, case-insensitive) logs a
`task_reported_error` failure for self-evolution when the task's reply
matches it - this catches tasks that degrade gracefully and report a broken
dependency inside an otherwise clean reply, which the transport-level failure
signals (stderr growth, post failure, timeout) cannot see. To see the live set:
```bash
jq -r '.tasks[] | "\(.name)\t\(.cron)\tenabled=\(.enabled)"' config/schedule.json
```

When adding or reviewing a task, ask whether it needs reasoning. If it does not,
give it a `command` instead of a `prompt_file`. Every `prompt_file` task goes
through the ONE shared session, so a fetch-aggregate-format job with no judgment
in it pays Claude to retype JSON into tables and grows the shared context while
it does so. One such task cost about 14 minutes and 45k tokens of pure
formatting; rewritten as a single-process script behind a `command` field it
finishes in about 4 seconds (`cron: dispatching '<task>' via command (no
Claude)`). `cron.sh` runs the command directly with a `timeout` and cwd `/app`,
and forwards stdout through the existing notify chunker, so there is no
bot-channel hop and no context growth. Keep the task's prompt file as a one-line
pass-through so `/retry` still works.

A task name in `schedule.json` is a stable identifier used by the command
system. Renaming one breaks `/retry <task>` until the change reaches the host,
so never rename a task that was not asked about.

## Deployment
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

### Host paths and `.env`
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
1. `git fetch`; if behind, stash local bot edits, `git pull --ff-only`, pop.
2. Rebuild gate, checked on EVERY run (not only when this script pulled): if `Dockerfile`/`docker/`/`docker-compose.yml` changed since the commit recorded in `state/.deployed-build-commit` (the commit the running image was built from; `deploy_rebuild_needed` in `lib/paths.sh`, `tests/deploy_gate.sh`) → `docker compose up -d --build --force-recreate`, record the new commit, then `docker image prune -f` to drop the 2.27GB image the retag just orphaned (dangling only, never `-a`). Gating on the marker instead of the pull catches commits born in the container's own bind-mounted tree (the bot commits and pushes, so HEAD is already at origin/main when the cron looks). On 2026-08-13 the bot committed a Dockerfile change inside the bind-mounted repo and pushed from there; the old `HEAD != origin/main` gate saw them equal and never rebuilt, so the change sat unbuilt for an hour while the bot reported "still building" (commits 3758340, 5525781). The marker is seeded from the PRE-pull commit, and a marker sha the repo does not recognise forces a conservative rebuild. `scripts/self-update.sh` takes a `flock` singleton because the marker only lands after the build finishes, so overlapping 5-minute ticks would otherwise double-build. A quiet, up-to-date run logs NOTHING, so an idle log is normal rather than a stalled cron.
3. Elif this run pulled and `watchers/`, `lib/*.sh` or `lib/channels/` changed → `docker kill --signal=HUP zoidberg`. (`lib/channels/` counts because the bot-channel MCP server is launched by the session: without a respawn the new file is on disk and the old server keeps running.) The SIGHUP re-execs the scheduler, which runs every plugin `_cleanup` (killing the tmux session) then re-inits and respawns the session with its new launch args and clean context.
4. Else (agents/scripts/docs) → no reload; those are read fresh at dispatch.
5. It also syncs the skills repo and the content repo (mirror sync blocks: fetch, stash-pull-pop if the mount has local edits, run `setup.sh` if present) and runs their setup scripts. A content pull that touched `agents/` also SIGHUPs: the session system prompt is assembled at spawn from the framework prompts plus `config/agents/*.local.txt`, so a prompt edit is invisible to the running session until it respawns. Task prompts and `config/scripts/` are read fresh at dispatch and trigger nothing.
6. Secret store, when `SECRET_STORE_REPO` is set in `.env`: sparse-mirror that git repo into `SECRET_STORE_PATH` (only `SECRET_STORE_FILE`, default `credentials.enc.json`, is checked out; `secret_store_mirror` in `lib/paths.sh`). When the mirrored ciphertext differs from `store/volume-backup/credentials.enc.json` (`secret_store_changed`) it is copied there (mode 600, uid 1000) and `docker exec zoidberg bash /app/docker/sync-secret-store.sh` decrypts it in place. No respawn: scheduled tasks and skills read the plaintext with `jq` at call time. The store is SOPS + age ciphertext, so a private repo can hold it; the container decrypts with the age key `docker-compose.yml` mounts at `/run/age-key.txt`. Rotating a credential is therefore: edit the store, commit, push; the host applies it within 5 minutes. `tests/secret_store_sync.sh` covers the mirror and change detection, `tests/secret_store_decrypt.sh` the in-container script (skips without `sops` and `age-keygen`).

So a `git push` to `main` is the entire deploy - the host applies it within 5
minutes. The bot also auto-pushes its own changes; `autoupdate.sh` is an
in-container backstop, not the primary mechanism.

The two race harmlessly for build changes now (the marker gate fires no matter
who pulled), but `autoupdate.sh` still classifies the incoming range with the
same two patterns (`_autoupdate_change_class`) and acts on it: build changes
are NOT pulled at all (no docker CLI or socket in the container),
`watchers/`/`lib/*.sh`/`lib/channels/` changes are pulled and followed by `kill -HUP 1`, and
everything else is pulled and left alone. The patterns must stay identical to
the host's; `tests/autoupdate_class.sh` asserts the classification.

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

### /reload vs /restart
- `/reload` (`kill -HUP 1`): scheduler re-execs, re-sources plugin code, and respawns the session (cleanup kills it, init relaunches with current args). Applies code already on disk. This is what `scripts/self-update.sh` triggers for `watchers/`/`lib` changes.
- `/restart` (`kill -TERM 1`): PID 1 exits and Docker recreates the container. Full reset.

## Adding a new task
1. Create the prompt file in `config/agents/` (or use a `command` for deterministic work).
2. Add an entry to `config/schedule.json` (name, cron, prompt_file OR command, enabled, model, effort).
3. That's it - the task whitelist is derived from `schedule.json`.

See `examples/content/` for the overlay layout, including a template for each
task type. `schedule.json` ships empty: a new install runs no tasks until you
add them.

## Keep Docs in Sync with Code
Documentation is part of the change, not an afterthought. When you add, remove,
rename, or restructure a component (plugin, lib file, command, scheduled task,
transport); change how the system is built, deployed, run, or configured; or
alter a documented workflow - update the docs that describe it in the SAME change.
- Docs describe the system as it IS now. Delete stale claims outright; do not append "(previously X)" caveats or layer corrections on top.
- Verify every doc claim against the code before writing it (file:line, real command output, actual config). The "Never Guess" rule applies to docs - a doc is a load-bearing assertion.
- If a doc names a file, command, plugin, endpoint, or task that was renamed or removed, fix or delete the reference. Keep inventories (Key files, Commands, Scheduled tasks) matched to what is on disk.
- A change is not complete until CLAUDE.md, README.md, and any `docs/` pages the change touches are correct.

## Features are opt-in

Core plugins (`claude_session`, `cron`, `autoupdate`) always load. Every other
`watchers/plugins/*.sh` is gated on `.features.<name>` in the operator's
`config.json` (`feature_enabled` in `lib/common.sh`, `CORE_PLUGINS` in
`watchers/scheduler.sh`). Unlisted means OFF, except `telegram`, which defaults
ON so pre-existing installs keep their interface. A disabled plugin is never
sourced. jq's `//` operator treats `false` as absent, so the lookup tests the key
with `has()` first: a naive `// "true"` silently re-enables a feature the
operator explicitly disabled. The full model is in `docs/ARCHITECTURE.md` ("The
feature model"), the
six-step procedure for adding one is `docs/features/README.md`, per-feature docs
live in `docs/features/<name>.md`, and `tests/feature_gate.sh` covers the gate.

A SIGHUP reload is not instant. It can take well over 18 seconds to reach
`scheduler: daemon started`. Poll for that line rather than sleeping a fixed
interval.

## Install is two stages

`install.sh` does only deterministic bootstrap: prerequisite detection (offered,
never forced), clone, seeding the overlay from `examples/content/`, creating the
mount points, and generating a random bridge key. It does not build, start, or
touch Telegram. `setup.sh run` drives the resumable sequence, and the `/setup`
skill (`.claude/skills/setup/SKILL.md`) runs in the operator's own Claude for
the judgment work: BotFather guidance, chat_id discovery through `getUpdates`,
config authoring, schedule authoring, the container build, the one-time
in-container OAuth, host cron entries, and end-to-end verification. Do not spawn
a second Claude on the host for this; the bot's own session authors the
schedule after the installer messages the owner to reply `/setup`.

Verification is mandatory, not optional. `docker/entrypoint.sh` hard-fails on
nothing, so a misconfigured install looks healthy while the session 401s
forever.

## Session auth expiry

When every Claude task hangs at once (Telegram replies hitting the 1200s wall,
cron tasks timing out, nothing completing), check the session's OAuth
credentials before looking at any individual task.

`claude auth status` is useless here. It reports `loggedIn: true` while every
call returns 401. The authoritative signal is the transcript: the newest
assistant record carries `isApiErrorMessage: true` with the text
`Login expired · Please run /login`. `_claude_session_auth_expired`
(`watchers/plugins/claude_session.sh:424`) reads that record, and
`claude_session_check_auth` sends a debounced Telegram alert on it each tick.
Rendered pane content cannot forge a transcript record, which is why the check
lives there instead of in a pane grep (622dd6e). An error record older than
the mtime of `~/.claude/.credentials.json` is ignored: after `/login` the
session resumes with `--continue` and takes no turn until the next dispatch, so
the pre-login 401 stays its newest assistant record and re-alerted on
2026-09-22 two minutes after a successful login (`tests/session_self_match.sh`).
The auth code is redacted from logs.

The access token lasts about 8 hours and refreshes itself. When the refresh
token dies, `.credentials.json` `expiresAt` sits in the past and everything 401s
until re-login. The fix needs no shell access: send `/login` in Telegram,
approve the URL the bot returns, then reply `/login <code>`. The handler
validates the new `expiresAt` and respawns the session, which is required
because the running session caches the dead token in memory. `/login` is a slash
command, so it bypasses the dead session.

## Context window and the 1M flag

`CLAUDE_CODE_DISABLE_1M_CONTEXT` is unset, and should stay unset.

On 2026-06-04 the interactive session hard-failed every dispatch with the literal
pane text `Usage credits required for 1M context`. Setting
`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` (commit d8460ce) forced a 200k window and
fixed it. That ran on a Sonnet 4.6-era model, which gates the 1M tier on usage
credits. Sonnet 5 has no such gate: it gets 1M context natively, with automatic
compaction near 967k tokens. Commit f37d319 removed the flag on 2026-07-25, and
a live check on 2026-08-01 found zero occurrences of `credits`, `1M context`,
`hang` or `hung` across 23,351 log lines, zero container restarts, zero OOM
kills, and a healthy idle session. `claude_session_maybe_clear`, a manual
`/clear` at 120k tokens, was deleted at the same time as redundant.

An earlier claim that auto-compaction is gated off in non-interactive or
tmux-piped delivery is RETRACTED. It was an inference chained onto the
credits-gate finding. No commit or log ever isolated compaction behaviour in
this delivery mode, and the seven clean days contradict it.

A second incident on 2026-07-01 (commits cafea74, a1949ba) is separate and still
unexplained. Removing the flag brought the session up idle with no error banner,
yet every channel request hung at low context. Restoring the flag fixed it
within 11 minutes. That is a different symptom from the credits-gate failure: no
banner, hung instead of rejected, at low context. Do not assume it was the same
root cause or a compaction failure. It has not recurred.

If either symptom returns, a literal credits banner or a silent hang at any
context size, re-add `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` to the compose
environment as the first response, and treat the recurrence as new evidence
rather than proof the original fix was right.

Diagnostic signature: `logs/automations.log` fills with
`bot_channel_wait_reply: timeout`. Confirm by reading the session screen,
`docker exec zoidberg tmux capture-pane -t zoidberg -p`. Every automation shares
ONE session, so context only grows between resets and a retry storm makes a jam
worse: once jammed, failed tasks keep being re-dispatched and each one adds more
context. `self-evolve` is rate-limited to once per `.evolution.cooldown_seconds`
(default 10800, three hours, `lib/evolution.sh:40`) for that reason.

## Scrape chrome, never content

On 2026-07-26 the bot stopped answering Telegram. `claude_session_is_busy`
grepped the ENTIRE tmux pane for `esc to interrupt`. `state/memory.md` quoted
that exact phrase, the memory-prune turn rendered the file as a diff into the
pane, and the grep matched its own documentation. The session reported busy
forever while it sat idle.

Everything gated on that check died silently. The Telegram idle-fallback in
`lib/telegram-run.sh` never reached `idle_streak` 2, so neither the reply-nudge
nor the transcript salvage fired, and every dispatch burned the full 1200s
`CLAUDE_WALL_TIMEOUT`. `claude_session_maybe_clear` deferred `/clear` forever.
`claude_session_apply_pending_model` never applied a deferred model switch. It
recurred every 15 exchanges, because that is when memory-prune runs.

Fixed in 4fb6cf4: scrape only the last two pane lines, the footer and the input
border, never conversation content. `tests/session_is_busy.sh` is the regression
test.

A pane scrape has three correct shapes, chosen by where the signal lives:
1. Fixed chrome, such as the busy footer. Bind to that region: `tail -n 2`.
2. Recorded structurally somewhere else. Read that instead, which is what the
   auth check does with the transcript's `isApiErrorMessage` record.
3. On screen only, such as an unanswered option picker. It must be scraped, so
   assemble the pattern from fragments to keep the literal out of the file.
   `tests/session_self_match.sh` uses `claude_session.sh`'s own source as a
   negative fixture and asserts no grepped literal appears in it. It immediately
   caught an explanatory comment reintroducing one.

A bot that writes documentation about its own internals into a file it later
renders on screen will feed its own scrapers. Any heuristic that greps a
rendered surface for a control string is one doc update away from breaking.

Diagnostic note: the container clock is UTC while the host may run local time,
so `logs/automations.log` can read hours behind wall time. That is not a frozen
log.

## WhatsApp bridge

The bridge (whatsmeow-based, `docker/whatsapp-bridge-src/`) was re-vendored from
upstream `FelixIsaac/whatsapp-mcp-extended` at tag v0.3.0 (commit de0bd63) on
2026-07-08. Upstream force-pushes its history, so always pin a SHA or a tag,
never track a branch. Provenance and the local patch list are in
`docker/whatsapp-bridge-src/UPSTREAM.md`, which makes the next convergence
mechanical: re-vendor pristine, then re-apply the listed patches (the flag shim
for `-store-dir` and `-listen`, the `/tmp/whatsapp-media` download dir, and the
`AUTO_DOWNLOAD_MEDIA` gate defaulting off).

`docker/whatsapp-mcp-server` is deliberately NOT converged. It is a structural
rewrite, a `lib/` REST-client split against upstream's 2359-line direct-DB
monolith. Treat it as our own fork and port individual upstream tools on demand.

### Webhook dispatch
Instant dispatch (webhook to the `whatsapp.sh` listener to
`lib/whatsapp-dispatch.sh`) had never worked until 2026-07-08. `webhook_logs`
had zero rows and `could not reach bridge API` appeared 113 times in
`automations.log`. Two independent causes:
1. The plugin's `GET` and `POST /api/webhooks` curls sent no `X-API-Key`, and
   the bridge has enforced auth since the Docker migration. Fixed in e736792.
2. Upstream v0.3.0 added an SSRF guard rejecting webhook URLs on private or
   loopback addresses, and our listener is `127.0.0.1` in the same container by
   design. Fixed with `export DISABLE_SSRF_CHECK=true` in
   `docker/entrypoint.sh:70`, upstream's own escape hatch
   (`internal/webhook/validation.go:60`).

The plugin conflates 401 with unreachable (`curl -f`), so the failure was silent
for months. Verify any bridge change by checking for `webhook_logs` ROWS, not
the registration log line. An end-to-end test needs a self-chat message from a
DIFFERENT linked device: a message sent through the bridge's own `/api/send`
does not loop back through its inbound handler.

### Re-pairing
Two failure modes show up:
1. `[Client WARN] Keepalive timed out`, then `KeepAlive: 3 consecutive failures,
   forcing disconnect+reconnect`, then `lookup web.whatsapp.com: no such host`,
   then `Disconnecting...`. DNS broke.
2. `Got 401: logged out from another device connect failure, sending LoggedOut
   event and deleting session`, then `Device logged out - please scan QR code to
   log in again`. The session was invalidated server-side, by another device
   claiming the slot or by expiry. The bridge keeps running but the session file
   under `store/` is purged.

The bridge does not fall back to QR pairing mid-process after a 401. It needs a
fresh process start with no valid session in `store/` before the QR prints. The
entrypoint starts it as a background process, so if it dies the container stays
up and nothing respawns it. If a restart reconnects and then immediately hits
the 401 again, kill and restart once more; the second start prints the QR.

WhatsApp allows four linked devices and each bridge takes one slot, so two
bridges can stay paired at the same time without kicking each other.

## Rules that came out of failures

### Ask when a short message is ambiguous
A short message with no clear subject can mean more than one thing. Ask one
clarifying question instead of guessing.

**Why:** "another" was read as "run the stats task again" when it meant "log
another hollow hold".

**How to apply:** a short message with no clear subject gets one question before
any action.

### A system's own log is not a source
When diagnosing why the system did something, do not treat its own log line as
ground truth for a factual claim. The log can BE the symptom of the bug.

**Why:** on 2026-07-24 a scheduled task that parses a chat leaderboard logged
"not #1 for week 2026-W30" every day, and that log was quoted back as proof the
rule had worked correctly. The owner pushed back: "I was 10 points ahead
yesterday". Fetching the real leaderboard showed he was first by 12 points. The
upstream bot had changed its format from `<@id> — N pts` to plain names, the
parser matched 0 rows, and 0 rows renders as "not #1". The log reported what the
code concluded, not whether the conclusion was correct.

**How to apply:** verify the automation's INPUTS against the real external
source, the actual message or API response, not its logs or state.

### Validate a failure mode before designing for it
The health probe (420fc2b) posts a synthetic channel event and respawns the
session after two unanswered probes.

**Why:** "resuming a wedged conversation could resume the wedge" was asserted as
design rationale without reading the logs. The logs refuted it, and the
exception it justified would have wiped context daily. Every wedge respawn
between 2026-08-02 and 2026-08-13 fired at about 02:04 UTC, minutes after the
daily 02:00 UTC restart. `_HEALTH_PROBE_LAST` started at 0, so the first probe
raced the session's startup (dialog accept, MCP handshake), timed out at 25s,
and the probe 180s later landed strike two. Zero content-caused wedges have ever
been observed. Fixed in a996332 by arming a one-probe-interval grace in
`claude_session_spawn` (`tests/health_probe_grace.sh`).

**How to apply:** check the observed failures before writing code for a
hypothesised one.

### Keep operator facts out of the framework
This repo is public. No hosts, IP addresses, repo URLs, credential paths, task
names or personal names go into framework code, tests, docs or commit messages.
Instance facts live in the private content overlay, in `config/OPERATIONS.md`.

### Scrubbing history needs a repo recreate
On 2026-07-24 this repo's history was squashed to a fresh root. A force-push
alone does NOT remove the old objects from GitHub: the pre-rewrite commits,
trees and blobs stayed retrievable through
`gh api repos/.../git/commits/<old-sha>` even after `git fetch <sha>` refused
them. Only deleting and recreating the repository, under the same name and URL
so no remote had to change, made every old SHA return 404 or 422.

### Renaming a host directory means migrating the volumes first
The compose project name derives from the directory, so renaming the directory
renames the named volumes. A fresh `wa-bridge-store` forces a WhatsApp QR
re-pair. Copy the volumes with a helper container before `compose up`.

### Scheduled tasks run sandboxed
A scheduled task can only read files under `/app`, so anything it needs must be
mounted or copied there. The shell inside the container is GNU, not BSD. Task
prompts reach work through APIs or a clone from a remote; they never reference a
path on the operator's workstation.

## Operator-specific deployment

This repo is the generic framework. Instance-specific facts (hosts, SSH targets,
secrets layout, backup bucket and retention, deploy quirks) live in the private
content overlay at `config/OPERATIONS.md`, not here.
