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
- `framework_prompt <name.txt>` - resolves a framework behavior prompt; a file
  at `${CONTENT_DIR}/agents/<name>.txt` overrides the shipped default at
  `${REPO_DIR}/agents/<name>.txt` (content-override-by-presence).

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

The session is PERSISTENT: it retains real conversation turns across dispatches.
Context is reset when it grows past a token threshold (`claude_session_maybe_clear`)
and by the daily host `scripts/scheduled-restart.sh`, which bounds how far it can
grow between resets.

### Session system prompt and trust model
Identity is verified by the TRANSPORT, never by message content: the Telegram
`chat_id` and WhatsApp JID come from `config/secrets.json` at startup; anything
else is untrusted data.

All stable context lives in the session's REAL system prompt, rebuilt at every
session spawn into `state/.session-system-prompt.txt` from:
- `agents/guardrails.txt` - non-negotiable limits and per-task-type privileges. Framework prompt, resolved via `framework_prompt`; a `config/agents/guardrails.txt` overrides it.
- `agents/telegram-system.txt` - operating instructions. Same resolution, overridable from `config/agents/telegram-system.txt`.
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
- `lib/channels/bot-channel/server.ts` - bot-channel MCP server (event in, `reply` tool out)
- `lib/common.sh` - shared utilities (JSON parsing, project matching, logging, notify)
- `lib/paths.sh` - host-side path resolution and the `.env` reader/writer, shared by `install.sh`, `setup.sh` and `scripts/self-update.sh`
- `lib/telegram-*.sh` - Telegram plugin helpers: `-api` (Bot API), `-commands`, `-md` (markdown), `-process`, `-queue`, `-run` (dispatch/stream), `-session` (sessions/history/prompt-sections)
- `lib/whatsapp-dispatch.sh` - WhatsApp triage dispatcher (called by the webhook listener)
- `lib/claude-login.sh` - Claude OAuth sign-in (tmux pane, URL scrape, bounded polls), shared by `setup.sh` and the Telegram `/login` handler
- `lib/evolution.sh` - self-evolve agent (detects failures, improves prompts)
- `agents/guardrails.txt` - non-negotiable guardrails (framework prompt, session system prompt)
- `agents/telegram-system.txt` - Telegram operating instructions (framework prompt, session system prompt)
- `agents/prompt-sections.txt` - attribution marker + section headers (framework prompt)
- `agents/*.txt` - framework behavior prompts only (guardrails, telegram-system, prompt-sections, memory-prune-prompt, self-evolve); resolved via `framework_prompt`, overridable from `config/agents/`
- `examples/content/` - starter layout for your own content overlay (see `examples/README.md`)
- `config/` - content overlay (a separate private repo you create, mounted or checked out here), resolved via `CONTENT_DIR`:
  - `config/schedule.json` - task schedule definitions (source of truth for the task whitelist)
  - `config/models.json` - model/effort preferences
  - `config/config.json` - central config (endpoints, Bitbucket workspace, git identity); gitignored, placed out-of-band on the host
  - `config/secrets.json` - Telegram bot token and chat ID; gitignored, placed out-of-band on the host
  - `config/agents/*.txt` - prompt files for scheduled tasks
  - `config/scripts/*` - run-scripts (`pre_check`/`command` entries in `schedule.json`)
  - `config/config.example.json`, `config/secrets.example.json` - templates for the two gitignored files above
- `scripts/self-update.sh` - host-cron git-driven deploy (pull + reload/rebuild + skills + content sync)
- `scripts/scheduled-restart.sh` - host-cron daily container restart (resets session context)
- `docker/entrypoint.sh` - container startup (auth check, git config, `exec scheduler.sh`)
- `install.sh` - one-command bootstrap: prerequisites, clone, content overlay, then `setup.sh run`
- `setup.sh` - deterministic setup dispatcher: usage text, output helpers, path resolution, `json_write`, `ask`, and the subcommand `case`
- `lib/setup-*.sh` - the subcommands themselves, sourced by `setup.sh`: `-telegram` (token, chat-id discovery, installer messages), `-config` (`feature`, `identity`, `env`, `status`), `-login` (Claude sign-in), `-cron` (host cron entries), `-verify` (end-to-end check), `-run` (the install sequence)

## Scheduled tasks
`config/schedule.json` is the source of truth; the task whitelist is derived
from it automatically. Each entry: `name`, `cron`, `enabled`, `model`, `effort`,
and either `prompt_file` (dispatches `${CONTENT_DIR}/<prompt_file>`, e.g.
`config/agents/<file>.txt`, to the session) or `command` (runs a shell command
directly, no Claude - for deterministic no-reasoning work). Optional
`pre_check` gates a run, and `notify_filter` suppresses output unless it
matches. To see the live set:
```bash
jq -r '.tasks[] | "\(.name)\t\(.cron)\tenabled=\(.enabled)"' config/schedule.json
```

## Deployment
Production is a Docker container (`zoidberg`, scheduler = PID 1) on a Linux
host. The repo is bind-mounted `${REPO_PATH:-.}` → `/app`; the skills repo
`${SKILLS_PATH:-../claude-skills}` → the container's skills dir; the content
repo `${CONTENT_PATH:-../zoidberg-config}` → `/app/config`
(`docker-compose.yml`), with `CONTENT_DIR=/app/config` set in the container
environment. `config/` joins `skills/` as a bind-mounted repo - same pattern,
separate repo. `docker/entrypoint.sh` reads git identity
(`.git.user_name`/`.git.user_email`) from `/app/config/config.json`, and
chowns `/app/config/secrets.json` (the bind-mount may land root-owned).

### Host paths and `.env`
Compose's relative defaults resolve against the compose file's directory, so
out of the box the mounts are "this repo, plus its two sibling repos". The real
paths are pinned in `.env` at the repo root, written by `env_write_defaults`
(`lib/paths.sh`) from `install.sh` and `setup.sh env`. It holds `REPO_PATH`,
`CONTENT_PATH`, `SKILLS_PATH`, `COMPOSE_PROJECT_NAME=zoidberg` (unpinned, the
project name would come from the directory basename and namespace the
`claude-home` and `wa-bridge-store` named volumes) and a detected
`SSH_KEY_PATH`. The writer only ever ADDS missing keys; an existing value is
never rewritten.

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

Deploy is git-driven via a host cron every 5 minutes (`scripts/self-update.sh`):
1. `git fetch`; if behind, stash local bot edits, `git pull --ff-only`, pop.
2. If `Dockerfile`/`docker/`/`docker-compose.yml` changed → `docker compose up -d --build --force-recreate`.
3. Elif `watchers/` or `lib/*.sh` changed → `docker kill --signal=HUP zoidberg`. The SIGHUP re-execs the scheduler, which runs every plugin `_cleanup` (killing the tmux session) then re-inits and respawns the session with its new launch args and clean context.
4. Else (agents/scripts/docs) → no reload; those are read fresh at dispatch.
5. It also syncs the skills repo and the content repo (mirror sync blocks: fetch, stash-pull-pop if the mount has local edits, run `setup.sh` if present) and runs their setup scripts.

So a `git push` to `main` is the entire deploy - the host applies it within 5
minutes. The bot also auto-pushes its own changes; `autoupdate.sh` is an
in-container backstop, not the primary mechanism.

The two race, and the host loop loses: it gates its whole rebuild-or-reload
decision on `HEAD != origin/main`, so a commit `autoupdate.sh` pulled first
leaves it with nothing to do. `autoupdate.sh` therefore classifies the incoming
range with the same two patterns (`_autoupdate_change_class`) and acts on it:
build changes are NOT pulled at all (no docker CLI or socket in the container)
so the host loop still sees them, `watchers/`/`lib/*.sh` changes are pulled and
followed by `kill -HUP 1`, and everything else is pulled and left alone. The
patterns must stay identical to the host's; `tests/autoupdate_class.sh` asserts
the classification.

`scripts/scheduled-restart.sh` (host cron, daily) restarts the container to reset the
interactive session's accumulated context.

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

## Operator-specific deployment

This repo is the generic framework. Instance-specific facts (hosts, SSH targets,
secrets layout, backup bucket and retention, deploy quirks) live in the private
content overlay at `config/OPERATIONS.md`, not here.
