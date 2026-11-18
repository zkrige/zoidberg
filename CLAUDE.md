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
to install somewhere else (see `docs/deployment.md`).

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
- `autoupdate.sh` - in-container backstop: pulls, self-reloads on scheduler-code changes, defers build changes to the host `scripts/self-update.sh` (see `docs/deployment.md`).

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

## Index of topic docs
Read the doc before working in its area.
- `docs/content-split.md` - framework vs content overlay, `content_path`, `framework_prompt`, `.local.txt` prompt additions.
- `docs/transport.md` - the always-on session, bot-channel, `reply` vs `progress`, session system prompt and trust model.
- `docs/telegram-bot.md` - Telegram bot behaviour, commands, named sessions.
- `docs/key-files.md` - inventory of every file and directory and what it does.
- `docs/scheduled-tasks.md` - `schedule.json` tasks, per-task model/effort switching, health probe, adding a task.
- `docs/deployment.md` - Docker deploy, `.env` paths, `self-update.sh`, `auto_push`, restarts, `/reload` vs `/restart`.
- `docs/install.md` - the two-stage install and mandatory verification.
- `docs/session-auth.md` - when every Claude task hangs: OAuth expiry diagnosis and `/login`.
- `docs/context-window.md` - 1M context flag, auto-compaction, model catalog setting, hang symptoms.
- `docs/scrape-chrome.md` - rules for scraping the tmux pane without reading its own content.
- `docs/whatsapp-bridge.md` - bridge vendoring, webhook dispatch, re-pairing.
- `docs/lessons.md` - incident write-ups: logs as evidence, validating failure modes, history scrubbing, volume migration.
- `docs/ARCHITECTURE.md`, `docs/features/README.md` - plugin contract, feature model, deploy model, adding a feature.

## Rules that came out of failures

### Ask when a short message is ambiguous
A short message with no clear subject can mean more than one thing. Ask one
clarifying question instead of guessing.

**Why:** "another" was read as "run the stats task again" when it meant "log
another hollow hold".

**How to apply:** a short message with no clear subject gets one question before
any action.

### Keep operator facts out of the framework
This repo is public. No hosts, IP addresses, repo URLs, credential paths, task
names or personal names go into framework code, tests, docs or commit messages.
Instance facts live in the private content overlay, in `config/OPERATIONS.md`.

### Scheduled tasks run sandboxed
A scheduled task can only read files under `/app`, so anything it needs must be
mounted or copied there. The shell inside the container is GNU, not BSD. Task
prompts reach work through APIs or a clone from a remote; they never reference a
path on the operator's workstation.

## Operator-specific deployment

This repo is the generic framework. Instance-specific facts (hosts, SSH targets,
secrets layout, backup bucket and retention, deploy quirks) live in the private
content overlay at `config/OPERATIONS.md`, not here.
