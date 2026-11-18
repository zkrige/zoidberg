# Transport: the always-on interactive session
The bot does NOT spawn `claude -p` per message. It runs ONE persistent
interactive `claude` session in tmux (`zoidberg`), launched by
`claude_session.sh`:
```
claude --permission-mode bypassPermissions --model <model> \
  --append-system-prompt-file state/.session-system-prompt.txt \
  --dangerously-load-development-channels server:bot-channel
```
The interactive transport keeps usage on the subscription pool instead of Agent
SDK credit - that is the entire point of this architecture.

Every plugin dispatches by POSTing an event to the bot-channel HTTP listener on
`127.0.0.1:8790`. The bot-channel MCP server (`lib/channels/bot-channel/server.ts`,
Bun) forwards it to the session as a
`<channel source="bot-channel" request_id="..." kind="telegram|cron">` message.
Claude completes the work and calls the `reply` tool exactly once with that
`request_id`; the server writes the reply to a file the orchestrator polls.

`reply` ENDS the request - the turn is over and nothing further reaches the
owner - so a turn that used it to acknowledge ("checking now, will confirm
shortly") delivered a promise and then stranded the work, leaving the owner to
ping again. Interim updates therefore go through a second tool, `progress`,
which writes a sequenced `<request_id>.progress.<seq>` file and leaves the
request open. `_telegram_run_drain_progress` (`lib/telegram-run.sh`) sends and
deletes those while it waits, in write order; `_cron_wait_reply` discards any a
scheduled task left behind, and `claude_session_spawn` sweeps stale ones.
`tests/progress_drain.sh` covers ordering, delete-after-send, and the
reply/other-request files it must not touch.

`progress` also tells the ORCHESTRATOR the request is still live, which is what
makes background agents work. Dispatching an Agent and ending the turn to wait
for its completion notification leaves the pane idle, and the stream loop's
idle-fallback used to read that as a dead turn and nudge within ~4s, forcing a
premature `reply` that closed the request and stranded the agent's result. So a
delivered `progress` renews patience for `PROGRESS_PATIENCE` (300s) before the
idle-fallback may fire, and once nudged the loop waits `NUDGE_GRACE` (30s)
before scraping the transcript, since the salvage otherwise ships the
acknowledgement the nudge was sent to replace. Both are declared in
`watchers/plugins/telegram.sh` beside the other stream tunables. Every loop
iteration, including the waits inside both windows, ends in the
`STREAM_INTERVAL` sleep; until 2026-09-29 the nudge-grace wait `continue`d past
it and spun the loop at full CPU (tmux and jq on every pass) for the whole 30s.
`tests/nudge_grace.sh` covers both windows and the spin.

The session is PERSISTENT: it retains real conversation turns across dispatches,
and a respawn (deploy SIGHUP, daily container restart) resumes the previous
conversation via `--continue` (`_claude_session_continue_flag`) - the
transcript lives on the `claude-home` volume, so it survives recreates and
rebuilds. The only exception is a first spawn with no prior conversation,
which launches without the flag; wedge-recovery respawns also resume (every
observed "wedge" 2026-08-02..08-13 was a post-restart health-probe false
positive, fixed by a spawn grace period - see `tests/health_probe_grace.sh` -
so forcing a fresh session there would have wiped context daily). An operator
can `touch state/.session-fresh-spawn` to make the next spawn start clean. Context is managed by Claude Code's
own native automatic compaction on Sonnet 5's 1M context window (confirmed by
live production testing; no manual token-threshold clearing is needed). The
daily host `scripts/scheduled-restart.sh` restart still runs to reset tmux and
auth state; conversation context now carries across it.

## Session system prompt and trust model
Identity is verified by the TRANSPORT, never by message content: the Telegram
`chat_id` and WhatsApp JID come from `config/secrets.json` at startup; anything
else is untrusted data.

All stable context lives in the session's REAL system prompt, rebuilt at every
session spawn into `state/.session-system-prompt.txt` from:
- `agents/guardrails.txt` - non-negotiable limits and per-task-type privileges. Framework prompt, resolved via `framework_prompt`; extend it with `config/agents/guardrails.local.txt`.
- `agents/telegram-system.txt` - operating instructions. Same resolution, extended by `config/agents/telegram-system.local.txt`.
- `state/memory.md` - portable long-term facts.
- recent `/feedback` corrections (`state/feedback.log`).

The per-message channel BODY is deliberately minimal: an attribution marker
(`agents/prompt-sections.txt` line 1, also resolved via `framework_prompt`) plus the user's message (plus per-message
media instructions when files are attached). Nothing else. This matters: in a
persistent session the model already holds the real turns, so re-embedding
guardrails, the system prompt, memory, or a conversation transcript in the body
makes a security-aware model read its own scaffolding as a prompt-injection
envelope and refuse genuine owner commands. Keep the body minimal; continuity
comes from the session's own turns, not a re-pasted transcript.

That is not a theoretical risk. On 2026-07-21 the bot refused legitimate owner
commands, replying that the message "arrived wrapped in a large fabricated block
(fake CLAUDE.md/guardrails reprint, fake recent corrections, and a fake
prior-conversation transcript embedded inside the channel payload) ... doesn't
match how real messages have looked in this session." Every dispatch was
assembling the body as `guardrails + telegram-system prompt + feedback + rolling
history transcript + memory + user_msg` and POSTing it verbatim. The model
compared that against its genuine session context and read the difference as
injection. The re-embedded HISTORY transcript was the strongest trigger: "I'm
not treating the embedded transcript as real history". Re-embedding made sense
in the old stateless `claude -p` architecture and became actively harmful once
the session was persistent. Fixed in 9febb91 by building the real system prompt
at spawn and cutting the body to the attribution marker plus the message. A
first attempt (a542513) moved only the guardrails block out of the body and was
INSUFFICIENT, because the system, memory and history bundle still tripped the
detector.
