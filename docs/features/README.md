# Adding a feature

This is the procedure for adding a new optional capability to the bot - a new
plugin that is off by default and can be turned on per-operator. Read
`docs/ARCHITECTURE.md` first, specifically "The feature model" and "The
plugin contract", for the mechanics this procedure relies on.

A feature is anything that is NOT one of the three core plugins
(`claude_session`, `cron`, `autoupdate` - see `CORE_PLUGINS` in
`watchers/scheduler.sh`). If you're extending a core plugin instead of adding
a new one, this procedure does not apply; core plugins always load and have
no feature flag.

## Procedure

### 1. Write `watchers/plugins/<name>.sh`

Implement the lifecycle hooks the scheduler will call:
`<name>_init` (optional), `<name>_tick` (required), `<name>_cleanup`
(optional), `<name>_on_wake` (optional). Minimal skeleton that logs and
no-ops:

```bash
#!/bin/bash
# watchers/plugins/<name>.sh - <one-line purpose>
# Required globals (set by orchestrator): REPO_DIR, CONTENT_DIR, STATE_DIR,
# LOGS_DIR, CONFIG (via get_config), SECRETS (via get_secret).

<name>_init() {
  log "<name>: initialized"
  return 0
}

<name>_tick() {
  : # do the periodic work here; self-throttle if you don't need every tick
}

<name>_cleanup() {
  : # stop any background process/listener you started, remove locks
}

<name>_on_wake() {
  : # optional: recover state after a sleep/wake gap
}
```

The file just needs to exist under `watchers/plugins/*.sh` with a basename
that becomes `<name>` - the scheduler discovers it by globbing that
directory (`scheduler.sh:94`) and will gate it as a feature automatically
because it is not in `CORE_PLUGINS`.

### 2. Declare config keys and secrets

Add any config the feature needs under its own namespace in
`config/config.json` - do not reuse another feature's keys. Document the
defaults in `config/config.example.json` too, since that file is what a new
operator copies from.

Any credential (API key, token, password) goes in `config/secrets.json`
(and its documented shape in `config/secrets.example.json`), never in
`config.json`, never in the framework repo, never hardcoded in the plugin
script. Read secrets at runtime via `get_secret '.namespace.key'`
(`lib/common.sh:154-160`).

### 3. Enable the feature

Add `"<name>": true` under `.features` in the operator's `config.json`:

```json
{
  "features": {
    "telegram": true,
    "whatsapp": false,
    "<name>": true
  }
}
```

Until this is set, `feature_enabled` treats the plugin as off
(`lib/common.sh:126-135`) and the scheduler never sources the file - the
feature costs nothing at runtime while disabled.

### 4. Extra image components (if needed)

If the feature needs something baked into the image (a compiled binary, an
extra package, an MCP server), add it to the `Dockerfile` behind a
`ARG`-gated build stage so operators who don't want the feature don't pay for
it:

```dockerfile
ARG ENABLE_<NAME>=0
RUN if [ "$ENABLE_<NAME>" = "1" ]; then \
      <install/build steps>; \
    fi
```

Use `0`/`1` rather than `false`/`true`: a `RUN` can be guarded by a shell test,
but a `COPY` cannot be made conditional, and the way around that is to select
between two build stages by interpolating the flag into a stage name. WhatsApp
is the worked example (`Dockerfile`): it defines `whatsapp-payload-1` (the real
build) and `whatsapp-payload-0` (an empty stand-in), then picks one with
`FROM whatsapp-payload-${ENABLE_WHATSAPP}`. With the default the expensive
stage never runs, and only the finished artifact crosses into the final image.

Expose the flag through `docker-compose.yml` under the service's `build.args`
(as `ENABLE_WHATSAPP` already is) so operators can enable it with
`ENABLE_<NAME>=1 docker compose up -d --build`, and can pin it per host in a
gitignored `.env` file so later rebuilds do not silently drop the feature.
This requires an image
**rebuild** (`docker compose up -d --build --force-recreate`), not a
`/reload` or `/restart` - see the reload-strategy matrix in
`docs/ARCHITECTURE.md`. A container restart alone re-runs the same image and
will not pick up a new build-arg.

### 5. Write `docs/features/<name>.md`

Follow the template below. This is the file an operator (or their Claude)
reads to decide whether to turn the feature on and how to configure it.

### 6. Verify

1. Reload: `/reload` in Telegram, or `docker kill --signal=HUP zoidberg`.
2. Check `logs/automations.log` for the startup line:
   `scheduler: daemon started (plugins: ..., <name>, ...)`.
3. Confirm `<name>` is **not** also listed in the companion
   `scheduler: features disabled: ...` line - if it is, the feature flag
   isn't set the way you expect (check for the jq `has()` gotcha described in
   `docs/ARCHITECTURE.md` if you're debugging a config value that looks right
   but isn't taking effect).
4. Exercise the feature's actual trigger (webhook call, cron fire, message)
   and confirm the expected log lines / Telegram output appear.

## Per-feature doc template

Each `docs/features/<name>.md` should have these headings:

- **What it does** - one paragraph.
- **Default** - on or off by default, and why.
- **Config keys** - table: key, meaning, default.
- **Secrets keys** - table: key, meaning. State plainly if none are needed.
- **Image components** - what (if anything) must be baked into the image,
  and whether that requires a rebuild.
- **Setup** - numbered steps, calling out any step a human must do outside
  this repo (creating a bot with a third party, pairing a device, etc.) and
  any time-boxed step (a window that expires if not completed in time).
- **Verify** - how to confirm it's working end to end.
- **Disable** - the config change to turn it back off, and what that does
  and does not stop (compare to Invariants in `docs/ARCHITECTURE.md` if the
  feature has any container-level component that ignores the flag).
