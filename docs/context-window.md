# Context window and the 1M flag

`CLAUDE_CODE_DISABLE_1M_CONTEXT` is unset, and should stay unset.

On 2026-06-04 the interactive session hard-failed every dispatch with the literal
pane text `Usage credits required for 1M context`. Setting
`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` (commit d8460ce) forced a 200k window and
fixed it. That ran on a Sonnet 4.6-era model, which gates the 1M tier on usage
credits. Sonnet 5 has no such gate: it gets 1M context natively, with automatic
compaction near 967k tokens by default. Commit f37d319 removed the flag on
2026-07-25, and a live check on 2026-08-01 found zero occurrences of `credits`,
`1M context`, `hang` or `hung` across 23,351 log lines, zero container restarts,
zero OOM kills, and a healthy idle session. `claude_session_maybe_clear`, a
manual `/clear` at 120k tokens, was deleted at the same time as redundant.

`docker-compose.yml`'s `environment` sets
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000` (added 2026-09-27), which lowers the
compaction trigger from the ~967k default to 500k tokens - the CLI's own
native setting (`autoCompactWindow`/`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, verified
against the installed CLI binary's strings, not the deleted manual-`/clear`
mechanism). It compacts sooner rather than letting the always-on session ride
to the edge of the window, at the cost of more frequent compactions. Since this
touches `docker-compose.yml`, self-update.sh's rebuild gate applies: the next
deploy tick recreates the container (`docker compose up -d --build
--force-recreate`), not just a SIGHUP.

`docker-compose.yml` also sets `CLAUDE_CODE_MODEL_CATALOG=0` (added
2026-10-01). Without it every `/model` this session sends (the health probe's
switch, when one is configured, cron per-task switches, the
`/opus`/`/sonnet`/`/haiku` commands) PATCHes the account's
`model_selector_state` on Anthropic's side, and that value is what every other
Claude Code install on the same login shows as "Default (recommended)". The
symptom was the owner's Mac picker intermittently reading "Default: Haiku 4.5".
Verified against the installed CLI 2.1.286: the write is skipped when the served
catalog is off, and `CLAUDE_CODE_MODEL_CATALOG` set to `0`/`false`/`no`/`off`
turns it off (`env_off`). Model switching inside the session is unaffected; the
picker falls back to the CLI's compiled model list.

An earlier claim that auto-compaction is gated off in non-interactive or
tmux-piped delivery is RETRACTED. It was an inference chained onto the
credits-gate finding. No commit or log ever isolated compaction behaviour in
this delivery mode, and the seven clean days contradict it.

A second incident on 2026-07-01 (commits cafea74, a1949ba) is separate and still
unexplained. Removing the flag brought the session up idle with no error banner,
yet every channel request hung at low context. Restoring the flag fixed it
within 11 minutes. That is a different symptom from the credits-gate failure: no
banner, hung instead of rejected, at low context. Do not assume it was the same
root cause or a compaction failure. It has not recurred.

If either symptom returns, a literal credits banner or a silent hang at any
context size, re-add `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` to the compose
environment as the first response, and treat the recurrence as new evidence
rather than proof the original fix was right.

Diagnostic signature: `logs/automations.log` fills with
`bot_channel_wait_reply: timeout`. Confirm by reading the session screen,
`docker exec zoidberg tmux capture-pane -t zoidberg -p`. Every automation shares
ONE session, so context only grows between resets and a retry storm makes a jam
worse: once jammed, failed tasks keep being re-dispatched and each one adds more
context. `self-evolve` is rate-limited to once per `.evolution.cooldown_seconds`
(default 10800, three hours, `lib/evolution.sh:40`) for that reason.
