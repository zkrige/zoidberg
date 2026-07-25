#!/bin/bash
set -e

echo "[entrypoint] Starting zoidberg container..."

# Fix volume ownership (volumes may be created as root)
sudo chown -R claude:claude /home/claude/.claude /opt/whatsapp-bridge-store 2>/dev/null || true

# Ensure state and logs dirs exist and are writable
mkdir -p /app/state /app/logs /app/store
sudo chown -R claude:claude /app/state /app/logs /app/store 2>/dev/null || true

# secrets.json may be bind-mounted as root; fix ownership
sudo chown claude:claude /app/config/secrets.json 2>/dev/null || true

# ---------------------------------------------------------------------------
# Restore critical configs from host backup if volume is fresh
# /app/store/ is on the host bind-mount, so it survives volume recreation.
# ---------------------------------------------------------------------------
BACKUP_DIR=/app/store/volume-backup

# Restore credentials.json if missing (fresh volume)
if [ ! -f ~/.claude/config/credentials.json ] && [ -f "$BACKUP_DIR/credentials.json" ]; then
  mkdir -p ~/.claude/config
  cp "$BACKUP_DIR/credentials.json" ~/.claude/config/credentials.json
  echo "[entrypoint] Restored credentials.json from host backup"
fi

# Restore Claude auth if missing (fresh volume)
if [ ! -f ~/.claude/.credentials.json ] && [ -f "$BACKUP_DIR/claude-credentials.json" ]; then
  cp "$BACKUP_DIR/claude-credentials.json" ~/.claude/.credentials.json
  echo "[entrypoint] Restored Claude auth from host backup"
fi

# Back up current configs to host (runs every start to keep backup fresh)
mkdir -p "$BACKUP_DIR"
for src_dest in \
  "$HOME/.claude/config/credentials.json:credentials.json" \
  "$HOME/.claude/.credentials.json:claude-credentials.json"; do
  src="${src_dest%%:*}"
  dest="${src_dest##*:}"
  [ -f "$src" ] && cp "$src" "$BACKUP_DIR/$dest" 2>/dev/null || true
done

# Check Claude CLI is available
if ! claude --version >/dev/null 2>&1; then
  echo "[entrypoint] WARNING: Claude CLI not authenticated. Run: docker exec -it zoidberg claude login"
fi

# Bridge API key: shared secret between the bridge server, the MCP server and the
# whatsapp scheduler plugin. It lives in the content overlay's secrets.json, not in
# the image or compose file. Exported here so every descendant process inherits it.
if [ -f /app/config/secrets.json ]; then
  export WHATSAPP_BRIDGE_API_KEY="${WHATSAPP_BRIDGE_API_KEY:-$(jq -r '.whatsapp.bridge_api_key // empty' /app/config/secrets.json)}"
fi

# Start WhatsApp bridge in background (if binary exists)
if [ -x /usr/local/bin/whatsapp-bridge ]; then
  echo "[entrypoint] Starting WhatsApp bridge..."
  export API_KEY="${WHATSAPP_BRIDGE_API_KEY:-}"
  # Webhook target is the scheduler's loopback listener in this same container;
  # the upstream SSRF guard would reject 127.0.0.1 registrations.
  export DISABLE_SSRF_CHECK=true
  /usr/local/bin/whatsapp-bridge \
    --store-dir /opt/whatsapp-bridge-store \
    --listen 0.0.0.0:8080 \
    >> /app/logs/whatsapp-bridge.log 2>&1 &
  echo "[entrypoint] WhatsApp bridge started (PID: $!)"
  sleep 2
fi

# Register the WhatsApp MCP server so the interactive session gets the
# mcp__whatsapp__* tools. Claude Code reads MCP servers from the project
# .mcp.json (/app/.mcp.json) and user scope (~/.claude.json) — NOT from
# ~/.claude/.mcp.json, which the previous code wrote to and which was silently
# ignored, so the session never had WhatsApp tools. Register in USER scope: the
# /opt/whatsapp-mcp-server path is container-only, so it must not go in the
# checked-in /app/.mcp.json (that would fail to load on the dev machine).
# ~/.claude.json is not on a persisted volume, so this must run every startup.
# Idempotent: drop any prior entry first.
# Only registered when the image was built with ENABLE_WHATSAPP=1 (the
# directory + uv only exist in that build); otherwise this would register a
# tool pointing at a command/path that don't exist in the default image.
claude mcp remove whatsapp -s user 2>/dev/null || true
if [ -d /opt/whatsapp-mcp-server ]; then
  if claude mcp add-json whatsapp \
    "{\"type\":\"stdio\",\"command\":\"uv\",\"args\":[\"--directory\",\"/opt/whatsapp-mcp-server\",\"run\",\"main.py\"],\"env\":{\"API_KEY\":\"${WHATSAPP_BRIDGE_API_KEY:-}\"}}" \
    -s user; then
    echo "[entrypoint] registered WhatsApp MCP server (user scope)"
  else
    echo "[entrypoint] WARNING: failed to register WhatsApp MCP server"
  fi
fi

# Copy SSH key with correct ownership and permissions
mkdir -p ~/.ssh
if [ -f /tmp/host-ssh-key ]; then
  sudo cp /tmp/host-ssh-key ~/.ssh/id_rsa
  sudo chown claude:claude ~/.ssh/id_rsa
  chmod 600 ~/.ssh/id_rsa
fi
ssh-keyscan -t rsa bitbucket.org github.com >> ~/.ssh/known_hosts 2>/dev/null

# Git config for skill edits (skills dir is a bind-mounted git repo)
git config --global user.name "$(jq -r '.git.user_name' /app/config/config.json)"
git config --global user.email "$(jq -r '.git.user_email' /app/config/config.json)"
git config --global --add safe.directory /home/claude/.claude/skills
git config --global --add safe.directory /app

# Log loaded skills
if ls /home/claude/.claude/skills/*/SKILL.md >/dev/null 2>&1; then
  echo "[entrypoint] Skills loaded: $(ls -d /home/claude/.claude/skills/*/ 2>/dev/null | wc -l) skills"
fi

# Copy configs into /app/store so scheduled tasks can read them (sandbox restricts to /app)
[ -f ~/.claude/config/credentials.json ] && cp ~/.claude/config/credentials.json /app/store/credentials.json 2>/dev/null || true
[ -f ~/.claude/skills/yti/config.json ] && cp ~/.claude/skills/yti/config.json /app/store/yti-config.json 2>/dev/null || true

# Pre-flight for interactive Claude session (channels architecture)
# Mark onboarding as completed and pre-trust /app project so `claude` doesn't
# show any startup wizard / consent dialogs.
if [ ! -f ~/.claude.json ]; then echo '{}' > ~/.claude.json; fi
jq '
  .hasCompletedOnboarding = true |
  .projects = (.projects // {}) |
  .projects["/app"] = ((.projects["/app"] // {}) + {
    hasTrustDialogAccepted: true,
    hasCompletedProjectOnboarding: true,
    enabledMcpjsonServers: ["bot-channel"],
    disabledMcpjsonServers: []
  })
' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json

# Suppress the bypass-permissions warning dialog and default to bypass mode.
# .tui is pre-seeded to the value Claude Code migrates to on first run: it
# applies that migration by re-execing itself WITHOUT preserving argv, which
# strips --model, --append-system-prompt-file and the bot-channel flag from the
# session and leaves it unable to answer any dispatch. Setting it up front means
# the migration never fires at runtime.
mkdir -p ~/.claude
if [ ! -f ~/.claude/settings.json ]; then echo '{}' > ~/.claude/settings.json; fi
jq '
  .permissions = (.permissions // {}) |
  .permissions.defaultMode = "bypassPermissions" |
  .skipDangerousModePermissionPrompt = true |
  .tui = (.tui // "fullscreen")
' ~/.claude/settings.json > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json

# Install bot-channel dependencies (fast if bun cache is warm)
if [ -f /app/lib/channels/bot-channel/package.json ]; then
  echo "[entrypoint] Installing bot-channel dependencies..."
  cd /app/lib/channels/bot-channel && /home/claude/.bun/bin/bun install --production 2>&1 | tail -3
  cd /app
fi

echo "[entrypoint] Starting scheduler..."
exec /app/watchers/scheduler.sh
