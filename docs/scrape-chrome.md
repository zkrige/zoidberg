# Scrape chrome, never content

On 2026-07-26 the bot stopped answering Telegram. `claude_session_is_busy`
grepped the ENTIRE tmux pane for `esc to interrupt`. `state/memory.md` quoted
that exact phrase, the memory-prune turn rendered the file as a diff into the
pane, and the grep matched its own documentation. The session reported busy
forever while it sat idle.

Everything gated on that check died silently. The Telegram idle-fallback in
`lib/telegram-run.sh` never reached `idle_streak` 2, so neither the reply-nudge
nor the transcript salvage fired, and every dispatch burned the full 1200s
`CLAUDE_WALL_TIMEOUT`. `claude_session_maybe_clear` deferred `/clear` forever.
`claude_session_apply_pending_model` never applied a deferred model switch. It
recurred every 15 exchanges, because that is when memory-prune runs.

Fixed in 4fb6cf4: scrape only the last two pane lines, the footer and the input
border, never conversation content. `tests/session_is_busy.sh` is the regression
test.

A pane scrape has three correct shapes, chosen by where the signal lives:
1. Fixed chrome, such as the busy footer. Bind to that region: `tail -n 2`.
2. Recorded structurally somewhere else. Read that instead, which is what the
   auth check does with the transcript's `isApiErrorMessage` record.
3. On screen only, such as an unanswered option picker. It must be scraped, so
   assemble the pattern from fragments to keep the literal out of the file.
   `tests/session_self_match.sh` uses `claude_session.sh`'s own source and its `claude_session/` parts as a
   negative fixture and asserts no grepped literal appears in it. It immediately
   caught an explanatory comment reintroducing one.

A bot that writes documentation about its own internals into a file it later
renders on screen will feed its own scrapers. Any heuristic that greps a
rendered surface for a control string is one doc update away from breaking.

Diagnostic note: the container clock is UTC while the host may run local time,
so `logs/automations.log` can read hours behind wall time. That is not a frozen
log.
