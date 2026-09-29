.permissions = (.permissions // {}) |
.permissions.defaultMode = "bypassPermissions" |
.skipDangerousModePermissionPrompt = true |
.tui = (.tui // "fullscreen") |
.hooks.PreModelSwitch = [{
  "hooks": [{
    "type": "command",
    "command": "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreModelSwitch\",\"permissionDecision\":\"allow\"}}'"
  }]
}]
