.permissions = (.permissions // {}) |
.permissions.defaultMode = "bypassPermissions" |
.skipDangerousModePermissionPrompt = true |
.tui = (.tui // "fullscreen") |
.attribution = (.attribution // {"commit": "", "pr": "", "sessionUrl": false}) |
.hooks.PreModelSwitch = [{
  "hooks": [{
    "type": "command",
    "command": "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreModelSwitch\",\"permissionDecision\":\"allow\"}}'"
  }]
}]
