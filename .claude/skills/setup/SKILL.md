---
name: setup
description: Guided install of the Zoidberg bot after install.sh has prepared the filesystem. Use this when the user asks to set up, configure, or finish installing the Zoidberg Telegram bot, when they say "/setup" or "run setup", or when they have just run install.sh and need the bot created, the schedule authored, and OAuth completed. This skill interviews the user and authors the schedule; `./setup.sh run` drives the actual install sequence.
---

# Setup: guided Zoidberg install

## You are the bot

`install.sh` prepares the filesystem and `./setup.sh run` does the whole
install, finishing by messaging the owner to reply `/setup`. That reply is how
you got here, so the container is up, Claude is signed in, Telegram is live and
cron is installed already.

So do not re-run install steps, do not send the owner off to the host to run
something, and do not tell them `/setup` cannot be used here. Your job is the
one thing `setup.sh` could not do: find out what they want automated and write
it. Edit `$CONTENT_DIR/schedule.json` and the prompts in `$CONTENT_DIR/agents/`
directly, then reload.

If something genuinely looks wrong, `./setup.sh status` and `./setup.sh verify`
will tell you what, and the diagnosis guidance below applies.

## Division of labor

`setup.sh` owns every deterministic mechanism AND the order to run it in:
preflight, disabling Telegram, Telegram token/chat_id discovery, git identity,
building and starting the container, Claude sign-in, re-enabling Telegram,
host cron, and verification. That ordering is not incidental (Telegram must
stay off until Claude can answer, or the owner's first message gets
dispatched to a session that cannot reply, hangs, and gets killed by the
health probe, making a correct install look broken). Ordering like that must
live in code, not be re-derived from prose each time.

Your job is everything `setup.sh` cannot decide for itself: interviewing the
owner about what they want automated, authoring `schedule.json` and its task
prompts, relaying the OAuth URL and collecting the code, and diagnosing
anything `verify` reports as broken. Never re-implement in prose (raw `curl`,
manual `jq` writes, polling loops) what a subcommand already does. Run
`./setup.sh --help` for the subcommand list if you need a reminder.

## Step 1: check current state

You are inside the container. `setup.sh status` and `setup.sh verify` drive
docker from the HOST and cannot work here: docker is not on your PATH, and the
container checks fail against nothing. Do not run them, and do not report their
failures as problems with the install.

What you can read from in here:

```bash
tail -30 /app/logs/automations.log
jq -r '.tasks[] | "\(.name)\t\(.cron)\tenabled=\(.enabled)"' "$CONTENT_DIR/schedule.json"
```

The log's most recent `daemon started` line lists the live plugins. You are
answering over Telegram right now, so the transport works. That is all the
confirmation you need before moving on.

## Step 2: interview the owner

Ask by putting the questions in the text you pass to `reply`, then end your
turn and wait for their next message. Never use an interactive prompt or option
picker: the owner is on Telegram and cannot answer one, so the turn hangs until
it is killed. Offer choices as a numbered list they can reply to in words.

A new install schedules NOTHING. That is deliberate: an automation that fires
before the owner asked for it is noise, and they will not trust the ones they
did ask for. So there is nothing to clean up, only something to add.

Do not open with an empty "what do you want?". Owners rarely have an answer
ready, and a blank prompt gets a blank response. Offer a short menu of things
that are useful on almost any box, say they can describe their own instead, and
ask for a cadence. Something like:

1. **Uptime check** - `command`, every 10 minutes, messages you only when a URL
   stops answering. Cheap, no Claude involved.
2. **Disk and memory check** - `command`, daily, messages you only when a
   threshold is crossed.
3. **Morning briefing** - `prompt_file`, daily, Claude reads whatever sources
   they name (calendar, inbox, a repo, a dashboard) and summarizes.
4. **Repo activity digest** - `prompt_file`, weekday mornings, open PRs and what
   needs their attention.
5. Something else they describe.

Pick from that list what actually fits what they tell you; it is a prompt to
think with, not a script to read out. For each task they choose, settle:

- The cadence (a specific time or interval).
- Whether it needs Claude's reasoning (`prompt_file`) or is a deterministic
  check with no judgment in it (`command`, faster and cheaper).
- For anything that runs often: should it message them every run, or only when
  something is wrong (`notify_filter`)? Default to only-when-wrong. A task that
  reports "all fine" every ten minutes gets muted, and then so does everything
  else.

One correctly working task is a good place to stop. More can be added any time
(Step 6).

## Step 3: author the schedule

Each entry in `$CONTENT_DIR/schedule.json` under `.tasks[]`:

| Field | Meaning |
|---|---|
| `name` | Unique task id. Do not rename later, renaming breaks `/retry` until synced. **Never a word someone might say to the bot conversationally** ("hello", "status", "hi"). A message that is exactly a task name is routed to `/retry <task>`, so a name like `hello` means the owner's first casual message re-runs a task instead of starting a conversation. Prefer `daily-report`, `pr-review`. |
| `cron` | Standard 5-field cron expression. |
| `enabled` | `true`/`false`. |
| `model` | `sonnet`, `opus`, or `haiku`. |
| `effort` | `low`, `medium`, `high`, or `max`. |
| `prompt_file` | Path relative to `$CONTENT_DIR`, e.g. `agents/my-task.txt`. Mutually exclusive with `command`. |
| `command` | Shell command run directly, no Claude reasoning. Mutually exclusive with `prompt_file`. |
| `pre_check` (optional) | Shell command; non-zero exit skips the run. |
| `notify_filter` (optional) | Regex; output only sent to Telegram if it matches. |

Write the tasks from the interview into `$CONTENT_DIR/schedule.json`. It ships
with an empty `tasks` array, so you are adding the first entries, not replacing
placeholders. Add only what the owner actually asked for.

For each `prompt_file` task, write the prompt to `$CONTENT_DIR/agents/<name>.txt`
(see `examples/content/agents/example-prompt.txt` for the shape). For each
`command` task, write the script under `$CONTENT_DIR/scripts/` (see
`examples/content/scripts/example-command.sh`, which reads config via the
`CONFIG_FILE`/`CONTENT_DIR` env contract). Those two files are templates showing
the shape; they are not scheduled and you do not need to keep them.

One correctly working task beats five untested ones. After writing:

```bash
jq -e . "$CONTENT_DIR/schedule.json" >/dev/null && echo "schedule.json valid JSON"
jq -r '.tasks[] | "\(.name)\t\(.cron)\tenabled=\(.enabled)"' "$CONTENT_DIR/schedule.json"
```

## Step 4: drive the install

```bash
cd "$REPO_DIR" && ./setup.sh run
```

This runs the entire deterministic sequence in the one order that works, and
resumes cleanly if re-run after a stop. It is interactive at exactly two
points:

1. **Telegram token**, only if not already stored. It prompts `Token: ` on
   stdin. Tell the user to open Telegram, message **@BotFather**, send
   `/newbot`, follow the prompts (a name, then a `_bot`-suffixed username),
   and paste the token it replies with. This one manual step cannot be
   automated. `run` then discovers the chat id itself: it asks the user to
   send any message to the new bot and polls for it, no action from you.

2. **Claude OAuth**, always. It prints a `https://claude.com/cai/oauth/authorize...`
   URL and prompts for the code (or Enter to defer). Relay the URL to the
   user, tell them to open it **on any device** and approve, then paste the
   code back to `run`. If they can't do it right now, pressing Enter exits
   `run` cleanly, mid-sequence, with everything before that point already
   done. Resume later with:
   ```bash
   ./setup.sh login <code>
   ./setup.sh run
   ```

`run` finishes by installing host cron and running `verify` itself; do not
run either separately unless you're targeting just one of them.

## Step 5: when verify fails, diagnose, do not retry hopefully

**`docker/entrypoint.sh` hard-fails on nothing.** A container reporting "Up"
is not evidence anything works: a misconfigured install can boot and look
healthy while the session sits 401ing forever or Telegram never replies.

```bash
docker exec zoidberg tail -200 /app/logs/automations.log
docker logs zoidberg --tail 200
```

Form a hypothesis from what you actually read there, then check it. don't
re-run `verify` and hope it passes on its own. Common causes: `secrets.json`
still has `REPLACE_ME`, Claude auth not actually completed (`./setup.sh
login` again), or the container needs a restart to pick up a config edit
made after it started.

## Step 6: skills are the user's own business

Explain, do not act: `$SKILLS_DIR` (`/opt/claude-skills`, mounted into the
container) is the user's own directory or git repo of Claude Code skills for
the bot to use. It can be empty, the bot still works with just its framework
prompts. Point at `examples/` for the shape of the content overlay, but do
NOT recommend, fetch, or install any specific skill. The user's toolset is
their choice.

## Step 7: enabling features later

```bash
./setup.sh feature <name> on
```

Then reload: `docker kill --signal=HUP zoidberg` for scheduler/plugin-only
changes, or `docker compose up -d --build --force-recreate` if the feature
also needs new image layers (e.g. a WhatsApp bridge binary). Point the user
at `docs/features/README.md` for the list of optional features. Do not
enable anything the user did not ask for.
