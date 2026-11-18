# Session auth expiry

When every Claude task hangs at once (Telegram replies hitting the 1200s wall,
cron tasks timing out, nothing completing), check the session's OAuth
credentials before looking at any individual task.

`claude auth status` is useless here. It reports `loggedIn: true` while every
call returns 401. The authoritative signal is the transcript: the newest
assistant record carries `isApiErrorMessage: true` and text ending
`Please run /login`. The prefix varies by cause and CLI version: `Login
expired` for a dead refresh token, `Login reached its time limit` (CLI 2.1.327,
`.credentials.json` `loginEnded: "time_limit"`, `expiresAt: 0`) when the login
hits its absolute lifetime. The check matches only the `Please run /login`
suffix; matching `Login expired` alone missed the time-limit form on
2026-11-17, so the bot sat down for 13 hours with no alert while the health
probe respawned the session every 7 minutes. `_claude_session_auth_expired`
(`watchers/plugins/claude_session/auth.sh:28`) reads that record, and
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
