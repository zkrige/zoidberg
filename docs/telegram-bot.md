# Telegram bot
- Messages are processed immediately (long-polling, not periodic).
- User-initiated messages run with `bypassPermissions` (you explicitly asked).
- Scheduled tasks post with `kind=cron`; the guardrails' SCHEDULED TASK RESTRICTIONS apply.
- If a scheduled task produces no output, you get a notification with `/retry <task>` to re-run with full permissions.
- All output goes to Telegram, via the bot token configured in `config/secrets.json`.

## Commands
| Command | Action |
|---------|--------|
| `/cancel` | Interrupt the running task (Escape into the session), drain queue |
| `/status` | Show running task, queue depth, model, session |
| `/session <name>` | Switch to named conversation session |
| `/sessions` | List all saved sessions |
| `/feedback <text>` | Log a correction (folded into the session system prompt) |
| `/feedback clear` | Clear the feedback log |
| `/reset` | Reset the active session's message log |
| `/opus` `/sonnet` `/haiku` | Switch Claude model (persisted; applied on next spawn) |
| `/low` `/medium` `/high` `/max` | Switch effort level |
| `/retry <task>` | Re-run a scheduled task with full permissions |
| `/login` | Start Claude OAuth login (when the session's auth expires) |
| `/reload` | `kill -HUP 1`: re-exec scheduler, re-source plugins, respawn the session |
| `/restart` | `kill -TERM 1`: exit PID 1 so Docker recreates the container |

## Named sessions
- Each exchange is appended to `state/sessions/<name>-messages.jsonl` for the record and for memory pruning. It is NOT re-injected into the prompt - continuity comes from the live session's own turns.
- `state/memory.md` holds long-term facts; it is folded into the session system prompt at spawn, and Sonnet prunes it periodically.
- `/reset` clears the active session's message log; `/session <name>` switches; `/sessions` lists.
