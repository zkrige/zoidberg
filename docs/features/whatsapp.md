# WhatsApp

## What it does

Watches your own WhatsApp self-chat (the "Message yourself" conversation) for
new messages via a webhook and triages them instantly - no cron delay. A
plain-text self-chat message is forwarded straight to Telegram at zero token
cost; a message prefixed with `!` is treated as a command and run through the
`whatsapp-triage` prompt in the interactive Claude session
(`lib/whatsapp-dispatch.sh:28-62`). Only messages in the configured self-chat
JID are ever processed (`whatsapp-dispatch.sh:42-45`); anything else is
ignored.

Implementation: `watchers/plugins/whatsapp.sh` (webhook listener + webhook
registration with the bridge) and `lib/whatsapp-dispatch.sh` (per-message
triage logic, invoked by the listener as a subprocess).

## Default

**Off by default.** Unlike Telegram, an absent `.features.whatsapp` key means
disabled (`lib/common.sh:126-135` - only `telegram` gets the "unset means on"
exception). `config/config.example.json` also ships it explicitly as
`"whatsapp": false`.

## Config keys

| Key | Meaning | Default |
|---|---|---|
| `.features.whatsapp` | Enable/disable the scheduler plugin | `false` |
| `.whatsapp.webhook_port` | Port the plugin's local webhook listener binds | `8769` |
| `.whatsapp.bridge_api` | Base URL of the WhatsApp bridge's HTTP API | `http://localhost:8080/api` |
| `.whatsapp.self_jid` | Your own WhatsApp JID (self-chat target) | none - must be set |
| `.whatsapp.self_jid_legacy` | Legacy JID form, used by `render_prompt` placeholder substitution | none |
| `.whatsapp.model` | Model for triage dispatches | `sonnet` |
| `.whatsapp.effort` | Effort for triage dispatches | `low` |
| `.whatsapp.notify_filter` | Regex; only forward triage output to Telegram if it matches | `ACTION REQUIRED\|FYI` |
| `.whatsapp.debounce_seconds`, `.whatsapp.target_group`, `.whatsapp.db_path` | Present in `config.example.json` but not read by `watchers/plugins/whatsapp.sh` or `lib/whatsapp-dispatch.sh` at the paths checked for this doc | - |

Read via `jq` directly against `content_path config.json` in
`watchers/plugins/whatsapp.sh:13-28` and again in `whatsapp-dispatch.sh:64-70`
(dispatch re-reads because it runs as a separate subprocess with only the
inherited env, not the scheduler's `CONFIG` variable).

## Secrets keys

| Key | Meaning |
|---|---|
| `.whatsapp.bridge_api_key` | Shared secret sent as `X-API-Key` to the bridge's HTTP API; also passed to the bridge process and the WhatsApp MCP server (`docker/entrypoint.sh:53-54,60,83`) |

The webhook itself is authenticated separately: `watchers/plugins/whatsapp.sh`
generates a random per-container HMAC secret on first run and persists it at
`state/whatsapp-webhook-secret.txt` (`whatsapp.sh:19-25`); the Python listener
verifies the bridge's `X-Webhook-Signature` header against it
(`whatsapp.sh:96-103`). This secret is generated, not configured - nothing to
set here.

## Image components

WhatsApp needs image components that are **not in a default build**. The
bridge binary and the Python MCP server are gated behind the
`ENABLE_WHATSAPP` build arg, which defaults to `0` (`Dockerfile:1,43`). With
the default, the Go toolchain, gcc, `uv`, the vendored bridge source, and the
MCP server never enter the image.

Build with the components included:

```bash
ENABLE_WHATSAPP=1 docker compose up -d --build
```

The `Dockerfile` selects between two payload stages via
`FROM whatsapp-payload-${ENABLE_WHATSAPP}`, so the disabled build never runs
the compile at all. Only the finished binary is copied into the final image;
the Go toolchain is left behind in the builder stage either way.

Runtime behaviour follows the image. `docker/entrypoint.sh` starts the bridge
only `if [ -x /usr/local/bin/whatsapp-bridge ]`, and registers the `whatsapp`
MCP server only `if [ -d /opt/whatsapp-mcp-server ]`. On a default build
neither exists, so neither runs.

Note the two switches are independent. `ENABLE_WHATSAPP=1` puts the bridge and
the MCP tools in the image; `.features.whatsapp` controls whether the
scheduler loads the `whatsapp` plugin (the webhook listener and triage
dispatch). Building with the components but leaving the feature off gives you
a running bridge and `mcp__whatsapp__*` tools in the session without automated
triage. You need both for the full feature.

## Setup

1. Rebuild the image with the WhatsApp components, which a default build omits:
   `ENABLE_WHATSAPP=1 docker compose up -d --build`. Confirm with
   `docker exec zoidberg ls -l /usr/local/bin/whatsapp-bridge`.
2. **Pair the device (human step, time-boxed).** On first connect with no
   stored session, the bridge prints a QR code to its log
   (`docker/whatsapp-bridge-src/internal/whatsapp/client.go:183-186`,
   `qrterminal.GenerateHalfBlock`). Watch it with
   `docker logs -f zoidberg` (or `tail -f logs/whatsapp-bridge.log`) right
   after a fresh container start, and scan it from WhatsApp on your phone
   (Linked Devices → Link a Device) **within 3 minutes**
   (`client.go:194-199`, `time.After(3 * time.Minute)`) - if the window
   expires before you scan, `Connect()` returns a timeout error and marks the
   client disconnected, which triggers the bridge's watchdog to restart the
   container so you get a fresh QR code and another 3-minute window. Paired
   sessions persist in the `wa-bridge-store` volume
   (`docker-compose.yml:12,35`) and reconnect automatically on subsequent
   boots without a new QR scan (`client.go:200-220`).
3. Set `.whatsapp.self_jid` (and `.whatsapp.self_jid_legacy` if you rely on
   `render_prompt`'s placeholder) in `config/config.json` to your own JID -
   found via the bridge's contact/chat listing once connected.
4. Set `.whatsapp.bridge_api_key` in `config/secrets.json` and make sure the
   same value is available to the container as
   `WHATSAPP_BRIDGE_API_KEY` (`docker-compose.yml:28` reads it from the host
   env as an override; `entrypoint.sh:53-54` otherwise pulls it from
   `secrets.json`).
5. Set `"features": {"whatsapp": true}` in `config/config.json`.
6. Reload (`/reload`, or `docker kill --signal=HUP zoidberg`) so the
   scheduler picks up the plugin. No further rebuild is needed at this point:
   step 1 already put the bridge and MCP server in the image, and this flag
   only gates the scheduler-side plugin.

## Verify

- `logs/automations.log` shows `whatsapp` in
  `scheduler: daemon started (plugins: ...)`, and the line
  `whatsapp: initialized (webhook listener on port <port>)`
  (`watchers/plugins/whatsapp.sh:40`).
- `whatsapp: webhook registered (id: ..., trigger: self-chat)`
  (`whatsapp.sh:183`) confirms the bridge accepted the webhook registration.
- Send yourself a WhatsApp message with a `!` prefix; within seconds you
  should see triage output on Telegram (subject to `.whatsapp.notify_filter`
  matching) and an entry in `logs/whatsapp-triage.log`.
- A plain-text self-chat message with no `!` should appear on Telegram
  prefixed `*[WhatsApp]*` (`lib/whatsapp-dispatch.sh:48-56`), with no Claude
  dispatch at all.

## Disable

Set `"features": {"whatsapp": false}` in `config/config.json` and reload.
This stops the webhook listener and all triage dispatch - no self-chat
message will reach Claude or Telegram anymore. It does **not** stop the
WhatsApp bridge process itself or unregister the `mcp__whatsapp__*` tools
from the interactive session (see Image components); those keep running as
long as the image was built with `ENABLE_WHATSAPP=1`. To remove them
entirely, rebuild with the default: `docker compose up -d --build`.
