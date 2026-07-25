# Telegram

## What it does

Long-polls the Telegram Bot API for messages from one authorized chat, queues
and dispatches them to the interactive Claude session, streams the response
back as it's produced, and implements the bot's `/`-commands (`/status`,
`/session`, `/feedback`, `/retry`, `/opus`/`/sonnet`/`/haiku`, `/reload`,
`/restart`, etc. - full list in the top-level `CLAUDE.md`). It is also the
default `notify` provider: `telegram_init` sets `NOTIFY_FN="tg_send"`
(`watchers/plugins/telegram.sh:58`), so cron task output and scheduler
notifications go to Telegram whenever this feature is on.

Implementation: `watchers/plugins/telegram.sh` plus its helpers
`lib/telegram-api.sh`, `-queue.sh`, `-session.sh`, `-run.sh`, `-commands.sh`,
`-process.sh` (all sourced in `telegram_init`, `telegram.sh:50-55`).

## Default

**On by default.** `feature_enabled` treats `telegram` as enabled when
`.features.telegram` is absent from `config.json` entirely
(`lib/common.sh:126-135`) - it is the only feature with this default,
because it is the bot's primary interface and this keeps installs that
predate the `.features` block working without a config change. Setting
`"features": {"telegram": false}` explicitly turns it off.

## Config keys

| Key | Meaning | Default |
|---|---|---|
| `.features.telegram` | Enable/disable the plugin | on if absent, per above |

No other `config.json` namespace is required for Telegram; model/effort are
controlled by the shared `.defaults` in `config/models.json` and the
`/opus`/`/sonnet`/`/haiku` and `/low`.../`/max` commands
(persisted to `state/telegram-model.txt` / `state/telegram-effort.txt`).

## Secrets keys

| Key | Meaning |
|---|---|
| `.telegram.bot_token` | Bot API token from BotFather |
| `.telegram.chat_id` | The single authorized chat ID (owner identity check) |

Read in `telegram_init` via `get_secret '.telegram.bot_token'` and
`get_secret '.telegram.chat_id'` (`telegram.sh:56-57`). If either is empty or
`"null"`, `telegram_poll` just sleeps out the poll interval and does nothing
(`telegram.sh:152-155`) - the plugin loads but is inert until both are set.

## Image components

None. Telegram only needs `curl` and `jq`, already installed in the base
image (`Dockerfile:5-9`). No build-arg, no extra binary, no rebuild required
to enable it.

## Setup

1. **Create the bot (human step, outside this repo).** Message
   [@BotFather](https://t.me/BotFather) on Telegram, run `/newbot`, follow
   the prompts. BotFather returns a bot token - this is
   `.telegram.bot_token` in `secrets.json`.
2. **Get the chat ID (human step).** Send any message to your new bot, then
   call `https://api.telegram.org/bot<token>/getUpdates` and read
   `result[0].message.chat.id` from the response. This is `.telegram.chat_id`
   in `secrets.json`. This is the value the transport checks every incoming
   message against (`telegram.sh:199`, `_telegram_process_update`) - messages
   from any other chat ID are silently dropped, so get this right.
3. Put both values in `config/secrets.json`:
   ```json
   { "telegram": { "bot_token": "<token>", "chat_id": "<chat_id>" } }
   ```
4. Ensure `.features.telegram` is not set to `false` in `config/config.json`
   (omit the key entirely, or set it to `true`).
5. Reload (`/reload` if the bot is already running some other way, or just
   start/restart the container).

## Verify

- `logs/automations.log` shows `telegram` in the
  `scheduler: daemon started (plugins: ...)` line, not in
  `scheduler: features disabled: ...`.
- Send the bot a message on Telegram; it should be picked up within one
  `POLL_TIMEOUT` (default 30s, `scheduler.sh:21`) and answered.
- `/status` should return without error.

## Disable

Set `"features": {"telegram": false}` in `config/config.json` and reload.
The plugin file is never sourced, so polling stops, no `/`-commands work, and
`notify()` falls back to log-only (`lib/common.sh:254-261`) unless another
feature has registered its own `NOTIFY_FN`. This also removes the bot's only
current interactive interface - confirm WhatsApp or another channel is
enabled first if you still want to reach the bot.

## Naming caution for scheduled tasks

A message that is exactly a task name is routed to `/retry <task>` rather than
treated as conversation (`lib/telegram-process.sh`, "bare task name"). Do not
name a task anything a person might reasonably say to the bot. `hello` was the
seeded example's task name and it meant a new owner's first "hello" silently
re-ran that task instead of starting a conversation. Prefer names that are
obviously job identifiers, such as `daily-report` or `pr-review`.
