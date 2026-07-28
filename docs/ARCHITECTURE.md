# Architecture

This is the living architecture description for the Zoidberg framework.
It describes the system as it exists in code today. When a component is added,
removed, renamed, or rewired, update this file in the same change.

## Overview

A single bash orchestrator (`watchers/scheduler.sh`) runs as PID 1 inside a
Docker container and sources a set of plugin scripts. The plugins feed work
into ONE always-on interactive `claude` session running in tmux. That session
is the only thing that ever talks to Claude: Telegram messages, WhatsApp
triage, and cron-scheduled tasks are all delivered to it as events over a
localhost MCP channel, and it replies by calling a `reply` tool.

## Components and responsibilities

| Component | File | Responsibility |
|---|---|---|
| Scheduler orchestrator | `watchers/scheduler.sh` | Singleton lock, plugin discovery/gating, lifecycle dispatch, SIGHUP reload, wake detection, hourly log rotation, main loop |
| Core plugin: session/transport | `watchers/plugins/claude_session.sh` | Owns the tmux session, the bot-channel POST/wait helpers, session health probing, context-size-based `/clear`, model switching |
| Core plugin: cron engine | `watchers/plugins/cron.sh` | Cron-expression matching, `pre_check` gates, dispatch of `command` and `prompt_file` tasks |
| Core plugin: autoupdate | `watchers/plugins/autoupdate.sh` | In-container `git fetch`/`pull --rebase` backstop, auto-push of bot-authored commits, ownership-drift healing, reload-or-defer on the pulled range |
| Optional plugin: Telegram | `watchers/plugins/telegram.sh` (+ `lib/telegram-*.sh`) | Long-polls the Bot API, queues/streams messages, implements `/`-commands |
| Optional plugin: WhatsApp | `watchers/plugins/whatsapp.sh` (+ `lib/whatsapp-dispatch.sh`) | Webhook listener, instant self-chat triage dispatch |
| Bot-channel MCP transport | `lib/channels/bot-channel/server.ts` | HTTP listener on `127.0.0.1:8790`; forwards events into the live session as an MCP notification; exposes the `reply` tool |
| Content overlay | `config/` (submodule) | Operator-specific config, secrets, schedule, task prompts, scripts - resolved via `CONTENT_DIR` |
| State | `state/` (`STATE_DIR`, `watchers/scheduler.sh:11`) | Per-task last-run markers, session system prompt, memory, feedback log, named session logs, in-flight locks |
| Logs | `logs/` (`LOGS_DIR`, `watchers/scheduler.sh:12`) | `automations.log` (orchestrator log via `log()`, `lib/common.sh:66-71`) plus per-task `<name>.log`/`<name>.err.log` |

## The transport: one always-on interactive session

The bot does **not** spawn `claude -p` per message. It launches ONE persistent
interactive `claude` process inside a tmux session named `zoidberg`
(`watchers/plugins/claude_session.sh:13`, launch command at lines 87-88):

```
cd /app && exec $CLAUDE_BIN --permission-mode bypassPermissions --model $model \
  --append-system-prompt-file $sysprompt_file \
  --dangerously-load-development-channels server:bot-channel
```

This is the single most important design decision in the codebase, and it is
deliberate for one reason: the interactive CLI keeps usage on the Claude
subscription pool. A per-message `claude -p` invocation would instead be
billed against Agent SDK API credit. Every other property of the system
(persistent conversation state, the channel protocol, the reply-file
round-trip, the context-clearing logic) exists to make one long-lived session
safely serve many independent callers, in exchange for that billing model.

### How a plugin dispatches

1. A plugin (cron, telegram, whatsapp) calls `bot_channel_post <request_id> <kind> <content>` (`watchers/plugins/claude_session.sh:153-169`), which POSTs JSON `{request_id, kind, content}` to `http://127.0.0.1:8790/`.
2. The bot-channel MCP server (`lib/channels/bot-channel/server.ts`, a Bun process registered as an MCP server inside the same `claude` invocation) receives the POST in its `Bun.serve` HTTP handler (lines 75-114) and turns it into an MCP notification `notifications/claude/channel` (line 106-109), with `meta.request_id` and `meta.kind` attached.
3. Claude Code renders that notification to the live session as a `<channel source="bot-channel" request_id="..." kind="...">` message (per the server's `instructions` block, lines 34-41).
4. The caller then calls `bot_channel_wait_reply <request_id> <timeout>` (lines 176-200), which polls for a reply file at `${BOT_CHANNEL_REPLIES_DIR}/<request_id>.txt` (default `~/.claude/channels/bot-channel/replies/`, `server.ts:23`).
5. Inside the session, Claude finishes the work and calls the `reply` MCP tool exactly once with `{request_id, text}`. The server writes it to a temp file and atomically renames it into place (`server.ts:64-68`), so the orchestrator only ever observes a fully-written reply.
6. `bot_channel_wait_reply` reads and deletes that file and returns the text to the caller (cron: `_cron_wait_reply`, `watchers/plugins/cron.sh:252-266`).

If the session is torn down mid-wait (a SIGHUP reload, a respawn), a
monotonically increasing generation marker at `state/.session-generation`
(written on every `claude_session_spawn`, `claude_session.sh:141`) lets
`bot_channel_wait_reply` detect that the request it is waiting on can never be
answered and fail fast instead of blocking out the full timeout
(`claude_session.sh:188-195`).

### Persistence and context management

The session is genuinely persistent: it retains real conversation turns
across dispatches from all sources (Telegram, cron, WhatsApp all share the one
session). Two things reset it:
- `claude_session_maybe_clear` (`claude_session.sh:314-331`) sends `/clear`
  once live context crosses a configurable token threshold
  (`.session.clear_context_tokens`, default 120000), but only when the session
  is idle and no dispatcher is still waiting on a reply
  (`_claude_session_dispatch_outstanding`, lines 296-304) - clearing mid-task
  would strand an in-flight `reply()` obligation.
- The host's daily `scripts/scheduled-restart.sh` restarts the whole container,
  which bounds context growth regardless of what the session has accumulated.

The session runs on whatever context window its model defaults to. Where that
default is 1M, the window is metered against usage credits rather than the
subscription, so a session left to grow into it can exhaust them and then fail
every dispatch. The three mechanisms above (auto-compaction, the idle context
reset, the daily restart) exist to keep it from getting there. If dispatches
start failing with a usage-credit error while the session is otherwise alive,
that is the cause, and `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` in the container
environment pins it to the standard window.

A non-blocking health probe (`claude_session_health_probe`,
`claude_session.sh:433-478`) periodically posts a synthetic channel event and
checks for its reply on later scheduler ticks, distinguishing "busy" (fresh
transcript writes within the probe window,
`_claude_session_transcript_fresh`, lines 376-382) from "wedged" (no writes,
no reply - respawn after `max_strikes` consecutive failures) from
"auth-expired" (401 banner on the pane - alert instead of respawn-looping,
lines 408-417).

## Framework and content split

This repo ships only generic scheduling/transport code and a small set of
framework behavior prompts. Everything operator-specific - `schedule.json`,
`models.json`, `config.json`, `secrets.json`, scheduled-task prompts
(`agents/<task>.txt`), and run-scripts (`scripts/*`) - lives in the separate
`config/` content overlay, resolved through a `CONTENT_DIR` env
(`lib/common.sh:167`, defaulting to `${REPO_DIR}/config`; overridden to
`/app/config` in production via `docker-compose.yml:11,25`).

Two helpers in `lib/common.sh` mediate the split:

- **`content_path <relative>`** (`lib/common.sh:163-168`) - returns
  `${CONTENT_DIR}/<relative>`, used for all operator content
  (`config.json`, `secrets.json`, `schedule.json`, `scripts/*`).
- **`framework_prompt <name.txt>`** (`lib/common.sh:170-181`) - resolves a
  framework behavior prompt with content-override-by-presence: if
  `${CONTENT_DIR}/agents/<name>` exists, that file wins; otherwise the shipped
  default at `${REPO_DIR}/agents/<name>` is used. This is how an operator
  customizes `guardrails.txt` or `telegram-system.txt` without forking the
  framework.

Operator content is externalized so the framework repo stays generic and
publishable: it carries no secrets, no personal task prompts, and no
operator-identifying config, while still letting an operator's overlay
override framework behavior prompts file-by-file.

## The feature model

Plugins fall into two categories, enforced in `watchers/scheduler.sh:88-107`:

```bash
CORE_PLUGINS=" claude_session cron autoupdate "
```

- **Core plugins always load**: `claude_session`, `cron`, `autoupdate`. These
  are the framework itself - the transport, the scheduler engine, and the
  deploy backstop. They never consult the feature flag.
- **Every other plugin is an optional feature**, gated on `.features.<name>`
  in the operator's `config.json`. The scheduler discovers plugins by
  globbing `watchers/plugins/*.sh` (line 94); for each file whose basename is
  not in `CORE_PLUGINS`, it calls `feature_enabled "<plugin_name>"`
  (`lib/common.sh:126-135`) and skips sourcing the file entirely if that
  returns false (`scheduler.sh:97-99`).

`feature_enabled` (`lib/common.sh:119-135`):

```bash
feature_enabled() {
  local name="$1" value
  # jq's // treats false as absent, so test for the key with has() instead.
  value="$(get_config "if ((.features // {}) | has(\"${name}\")) then (.features.\"${name}\" | tostring) else \"unset\" end")"
  if [ "$value" = "unset" ]; then
    [ "$name" = "telegram" ]
    return
  fi
  [ "$value" = "true" ]
}
```

An unlisted feature is OFF, with one exception: `telegram` defaults ON when
the `.features` key is absent entirely, because it is the default interface
and this keeps installs that predate the feature-flag block working without a
config change. The `has()` check exists because jq's `//` alternative
operator treats a JSON `false` the same as `null`/absent - a naive
`.features.whatsapp // "true"` would silently re-enable a feature the operator
explicitly turned off (`"whatsapp": false`). Testing for key presence with
`has()` first is what makes an explicit `false` distinguishable from "not
configured."

Because a disabled plugin's file is never `source`d, a dormant feature costs
nothing at runtime: no functions defined, no background listener started, no
`_init`/`_tick` hooks registered. (One caveat specific to the current
WhatsApp feature is documented in `docs/features/whatsapp.md` - the WhatsApp
bridge binary itself is started by `docker/entrypoint.sh`, independent of this
flag; see Invariants below.)

Skipped plugins are logged once at startup:
`scheduler: features disabled: <names>` (`scheduler.sh:107`); loaded plugins
appear in `scheduler: daemon started (plugins: <names>, poll: ...)`
(`scheduler.sh:118`).

## The plugin contract

Every file in `watchers/plugins/*.sh` is sourced (if not gated off) into the
scheduler's own process - plugins are not subprocesses, they share the
scheduler's bash state, and are sourced in alphabetical glob order
(`scheduler.sh:94`). `lib/common.sh` is sourced once by the scheduler itself
(`scheduler.sh:9`) before any plugin loads, so every plugin can already call
`log`, `content_path`, `framework_prompt`, `get_config`, `feature_enabled`,
`notify`, etc. regardless of plugin load order.

Lifecycle hooks, named `<plugin>_<hook>`, called by the orchestrator:

| Hook | Required | When | Example |
|---|---|---|---|
| `<plugin>_init` | optional | once, after all plugins are sourced (`scheduler.sh:110-114`); non-zero return is logged but the plugin stays loaded ("may be degraded") | `cron_init` checks `SCHEDULE_FILE` exists (`cron.sh:287-294`) |
| `<plugin>_tick` | **required** | every main-loop iteration, no interval built in - plugins self-throttle | `autoupdate_tick` checks its own `_AUTOUPDATE_INTERVAL` (`autoupdate.sh:36-42`); `cron_tick` only re-checks tasks once per new minute (`cron.sh:298-305`) |
| `<plugin>_cleanup` | optional | on SIGHUP (before re-exec) and on process exit (`trap cleanup EXIT INT TERM`, `scheduler.sh:49`) | `claude_session_cleanup` kills the tmux session (`claude_session.sh:518-520`) |
| `<plugin>_on_wake` | optional | when the loop detects a gap greater than `2 * POLL_TIMEOUT` since the last iteration (system sleep/resume) (`scheduler.sh:136-148`) | `telegram_on_wake` clears a stale busy lock and drains the queue (`telegram.sh:139-146`) |

Globals a plugin may rely on (all set by `scheduler.sh` or `lib/common.sh`
before plugins load): `REPO_DIR`, `CONTENT_DIR`, `STATE_DIR`, `LOGS_DIR`,
`SKILLS_DIR`, `CONFIG` (parsed JSON string; use `get_config <jq_path>`),
`SECRETS` (via `get_secret`), `CLAUDE_BIN`, `GUARDRAILS`, `MAX_CONCURRENT`,
`POLL_TIMEOUT`, `SCHEDULE_FILE`, `MODELS_FILE`, `DEFAULT_MODEL`,
`DEFAULT_EFFORT`.

Logging convention: call `log "<plugin>: <message>"` (`lib/common.sh:66-71`)
- appends a timestamped line to `logs/automations.log`. There is no per-plugin
log level; grep by the `<plugin>:` prefix. Failures worth surfacing to the
self-evolve agent go through `log_failure` (`lib/evolution.sh`, sourced by
`scheduler.sh:85`), not plain `log`.

Failing gracefully: an `_init` that returns non-zero does not unload the
plugin (`scheduler.sh:111-113` only logs a warning) - a plugin whose init can
fail (e.g. `cron_init` when `SCHEDULE_FILE` is missing) must make its own
`_tick` a no-op in that state rather than assuming init succeeded. A plugin
file that fails to `source` at all (syntax error) is skipped and excluded
from `PLUGINS[]` entirely (`scheduler.sh:101-104`), so its hooks are simply
never called.

## The scheduled-task env contract

`cron.sh` dispatches two kinds of `schedule.json` task: a `command` (runs a
shell script directly, no Claude involved) or a `prompt_file` (posted into the
interactive session via the bot-channel transport). Both `command` tasks and
any configured `pre_check` script receive the same exported environment,
built by `_export_task_env` (`watchers/plugins/cron.sh:186-191`):

```bash
_export_task_env() {
  export CONTENT_DIR APP_DIR="$REPO_DIR" STATE_DIR SKILLS_DIR="${REPO_DIR}/skills"
  export CONFIG_FILE="$(content_path config.json)"
  export SECRETS_FILE="$(content_path secrets.json)"
}
```

That is: `CONTENT_DIR`, `APP_DIR` (= `REPO_DIR`), `STATE_DIR`, `SKILLS_DIR`,
`CONFIG_FILE`, `SECRETS_FILE`. `pre_check` scripts run with this env from
`_cron_run_precheck` (`cron.sh:175-184`); `command` tasks run with it from
`_cron_dispatch_command`, which also `cd`s to `$REPO_DIR` first
(`cron.sh:193-215`, `cd "$REPO_DIR"` at line 196). A `command`/`pre_check`
task therefore always runs with cwd `$REPO_DIR` (`/app` in production) and can
read `$CONFIG_FILE`/`$SECRETS_FILE` directly without knowing the `CONTENT_DIR`
resolution rules itself.

`prompt_file` tasks do not get this env - they are text posted into the
session, not a subprocess, so the running Claude turn already has full tool
access; there is nothing to export.

Prompt-file paths are gated: `_cron_gate_prompt_path` (`cron.sh:150-161`)
blocks any `prompt_file` not matching `agents/*.txt` (relative to
`CONTENT_DIR`), unless the task also carries a `command`. Unknown task names
are blocked via `is_allowed_task` (`lib/common.sh:202-207`), which checks the
name exists in `schedule.json` - this is what makes `schedule.json` the
source of truth for the task whitelist described in the top-level `CLAUDE.md`.

## Deploy model

Deploy is git-driven via a host cron running `scripts/self-update.sh` every 5 minutes
(the crontab entry itself lives outside this repo). The reload strategy is a
matrix keyed on which paths changed between the local and remote HEAD
(`scripts/self-update.sh`):

| Changed paths | Action |
|---|---|
| `Dockerfile`, `docker/`, `docker-compose.yml` | `docker compose up -d --build --force-recreate` - full image rebuild and container recreate |
| `watchers/` or `lib/*.sh` (and the above did not match) | `docker kill --signal=HUP zoidberg` - in-place graceful reload |
| anything else (agents/scripts/docs only) | no reload - these are read fresh at dispatch time, nothing is cached in the running process |

`docker/entrypoint.sh` is **baked into the image** (`Dockerfile:69-70`,
`COPY docker/entrypoint.sh /entrypoint.sh`), unlike `watchers/` and `lib/`
which are bind-mounted and live-editable. Changing `entrypoint.sh` therefore
only takes effect after a full rebuild (the first row of the table above,
since `docker/` matches that path glob) - a SIGHUP reload cannot pick it up,
because SIGHUP only re-execs the already-running `scheduler.sh` process; it
never re-runs the entrypoint.

`scripts/self-update.sh` also mirrors the same fetch/stash/pull-pop pattern for
two sibling bind-mounted repos, the skills repo (`$SKILLS_PATH`) and the content
repo (`$CONTENT_PATH`), running each one's `setup.sh` if present after a pull
(`scripts/self-update.sh`). Both paths come from `resolve_host_paths`
(`lib/paths.sh`), which reads the repo's `.env`, so the rebuild it triggers
mounts the same directories the install actually uses rather than compose's
built-in defaults.

`/reload` (Telegram command, `kill -HUP 1`) and `/restart` (`kill -TERM 1`)
give an operator the same two levers manually: `/reload` re-execs the
scheduler and respawns the session with code already on disk; `/restart`
exits PID 1 so Docker recreates the container from the current image
(picking up an image rebuild if one already happened).

## Invariants worth stating

- **Identity is verified by the transport, never by message content.** The
  Telegram `chat_id` and WhatsApp JID are read from `config/secrets.json` at
  daemon startup and compared against the incoming transport's own metadata
  (`telegram.sh:199` compares `msg_chat_id` to `$TG_CHAT_ID`;
  `whatsapp-dispatch.sh:42-45` compares the webhook's `chat_jid` to
  `$WHATSAPP_SELF_JID`). A message body claiming "I am the owner" is always
  untrusted data, never a credential.
- **The per-message channel body stays minimal.** Guardrails, the operating
  system prompt, portable memory, and recent `/feedback` corrections are all
  assembled once into the session's real `--append-system-prompt-file`
  (`claude_session.sh:61-80`), not re-embedded in every dispatched message.
  A persistent session already holds its own real turns; re-pasting that
  scaffolding into the body reads to a security-aware model as a fabricated
  prompt-injection envelope and has caused it to refuse genuine owner
  commands (see the note at `claude_session.sh:49-60`).
- **Secrets never live in the framework repo.** `config/secrets.json` lives
  in the content overlay, is `.gitignore`d there, and is placed out-of-band on
  the host. The framework repo (`Zoidberg` itself) contains no
  operator secrets, account IDs, or JIDs - see the `render_prompt`
  placeholder mechanism (`lib/common.sh:189-197`) for how per-operator values
  are kept out of tracked prompt text entirely.
- **A container-level component can run independent of its feature flag.**
  `docker/entrypoint.sh:57-70` starts the WhatsApp bridge binary and registers
  its MCP server (lines 72-88) unconditionally whenever
  `/usr/local/bin/whatsapp-bridge` exists in the image - it does not consult
  `.features.whatsapp`. Only the scheduler-level `whatsapp` plugin (the
  webhook listener that actually triages messages) is gated by
  `feature_enabled`. See `docs/features/whatsapp.md`.
