# Scheduled tasks
`config/schedule.json` is the source of truth; the task whitelist is derived
from it automatically. Each entry: `name`, `cron`, `enabled`, `model`, `effort`,
and either `prompt_file` (dispatches `${CONTENT_DIR}/<prompt_file>`, e.g.
`config/agents/<file>.txt`, to the session) or `command` (runs a shell command
directly, no Claude - for deterministic no-reasoning work). Optional
`pre_check` gates a run, `notify_filter` suppresses output unless it
matches, and `error_filter` (regex, case-insensitive) logs a
`task_reported_error` failure for self-evolution when the task's reply
matches it - this catches tasks that degrade gracefully and report a broken
dependency inside an otherwise clean reply, which the transport-level failure
signals (stderr growth, post failure, timeout) cannot see. To see the live set:
```bash
jq -r '.tasks[] | "\(.name)\t\(.cron)\tenabled=\(.enabled)"' config/schedule.json
```

When adding or reviewing a task, ask whether it needs reasoning. If it does not,
give it a `command` instead of a `prompt_file`. Every `prompt_file` task goes
through the ONE shared session, so a fetch-aggregate-format job with no judgment
in it pays Claude to retype JSON into tables and grows the shared context while
it does so. One such task cost about 14 minutes and 45k tokens of pure
formatting; rewritten as a single-process script behind a `command` field it
finishes in about 4 seconds (`cron: dispatching '<task>' via command (no
Claude)`). `cron.sh` runs the command directly with a `timeout` and cwd `/app`,
and forwards stdout through the existing notify chunker, so there is no
bot-channel hop and no context growth. Keep the task's prompt file as a one-line
pass-through so `/retry` still works.

A task name in `schedule.json` is a stable identifier used by the command
system. Renaming one breaks `/retry <task>` until the change reaches the host,
so never rename a task that was not asked about.

## Per-task model/effort actually switch the session

`config/models.json` (`.tasks.<name>.model`/`.effort`, falling back to
`.defaults`) is read by `cron.sh`'s `_cron_apply_models_override`
(`watchers/plugins/cron.sh:147`) into `task_model`/`task_effort`. Before
2026-09-27 that override was parsed and then never used again: the shared
session only ever ran on whatever model it was launched with (persisted in
`state/telegram-model.txt`, applied on the next `claude_session_spawn`), so
`bitbucket-pr`'s `"opus"` entry was dead configuration.

`_cron_dispatch_botchannel` (`watchers/plugins/cron.sh:281`) now applies it for
real, per dispatch, using the CLI's own interactive `/model <name>` and
`/effort <level>` commands (`claude_session_switch_model`,
`watchers/plugins/claude_session/model.sh`) instead of a respawn, keeping the running
conversation and its `--continue` context intact. `/effort` switches
immediately. `/model` in a conversation with a warm prompt cache opens a
"Switch model?" confirm (the history is re-read on the new model), and while
that picker is open the session enqueues every channel event and dequeues none.
On 2026-09-29 that wedged the bot on every cron dispatch: the probe saw no
reply twice, respawned, killed the task, and the next dispatch repeated it.
`docker/claude-settings.jq` (applied by `docker/entrypoint.sh` at every start)
installs a `PreModelSwitch` hook answering `permissionDecision: "allow"`, the
CLI's own documented way to skip that confirm (CLI 2.1.284 hook schema: "allow
proceeds (skipping the interactive cache-miss confirm)");
`tests/claude_settings.sh` covers it. Diagnostic signature of a recurrence:
`queue-operation` `enqueue` records in the transcript with no `dequeue`, and a
picker on the pane. A cron dispatch whose session respawns mid-wait
(`bot_channel_wait_reply` returns 2) clears its `state/.<task>.inflight`
marker, since that run is dead; before 2026-09-29 the marker survived and the
task skipped every tick for `INFLIGHT_STALE` (30 minutes)
(`tests/cron_respawn_marker.sh`). A timeout (return 1) still keeps the marker,
because that run may still be executing. Verified live on 2026-09-27: both commands also print
"saved as your default for new sessions" - they write the CLI's OWN persisted
default (not `telegram-model.txt`, which only the bot's `/opus`/`/sonnet`/
`/haiku` Telegram commands touch), so every switch-and-restore cycle
overwrites and restores that file too. Each call only sends `/model`/`/effort`
when the target actually differs from the value passed as "current"
(`claude_session_switch_model`'s 3rd/4th args), so a task or probe whose
target already matches the live default sends neither. The switch only fires when
the task's model/effort differ from the standing default
(`_claude_session_persisted_model`/`_effort`, reading the same
`telegram-model.txt`/`telegram-effort.txt` the respawn path uses).
`_cron_prepare_session` takes the lock for EVERY dispatch, switch or not, and
then waits up to `CRON_IDLE_WAIT` (60s) for the session to go idle
(`claude_session_is_busy`/`BUSY_LOCK`) before it switches and posts. Only a
session still busy after that dispatches mid-turn on the active model. On
2026-10-08 the old immediate fallback posted a scheduled task into a running health-probe
turn on haiku/low: the event arrived as a queued in-turn notice, and haiku
refused it as external input (`tests/cron_session_prepare.sh`). A dispatch that
did not switch releases the lock right after its post. `MODEL_SWITCH_LOCK` (`${STATE_DIR}/.model-switch.lock`, flock'd on a
fixed fd per caller: 8 in the scheduler process for the health probe, 9 in each
backgrounded cron dispatch) serializes every switch so two dispatchers can
never interleave `/model`/`/effort` keystrokes into the one shared pane. The
cron dispatcher (fd 9) runs in its own backgrounded process, so it can afford
a blocking wait (`MODEL_SWITCH_LOCK_TIMEOUT`, 45s) before falling back to
dispatching on the active model. The health probe (fd 8) runs synchronously
inside the main scheduler loop instead, so it uses `flock -n` (non-blocking):
on 2026-09-27 it briefly used the same 45s blocking wait, and a long opus
`bitbucket-pr`/`github-pr-review` turn holding the lock for its full runtime
froze the scheduler loop for up to 45s at a time on every probe tick that
contended with it, delaying the probe's own resolution enough to trip 17 false
"wedged" respawns in 9 hours, killing whatever cron task was mid-flight at the
time as collateral damage. `flock -n` fails instantly instead: if the lock is
held, the probe just runs on the active model for that cycle rather than
freezing the loop. After the reply lands
(or the post/wait fails), `_cron_restore_session` waits for the task's turn to
end and then switches back to the standing default before releasing the lock.
The wait matters because the session keeps writing after its `reply` call, and
the CLI drops `/effort` typed mid-turn (verified against 2.1.294), which left
the session on the task's effort. `bitbucket-pr` and `github-pr-review` are opus in
`models.json`; every other `prompt_file` task falls through to the defaults
block (sonnet). A `command` task (`website-stats`, `gsc-fix`, `boom`,
`boom-check-win`, `import-sweep`, `container-restart`) never reaches Claude at
all (`_cron_run_task`, `watchers/plugins/cron.sh:105`), so a `models.json` entry
for one is dead - `website-stats` and `gsc-fix` carried one until 2026-09-27;
removed rather than left to imply a model that never runs.

The health probe (`claude_session_health_probe`,
`watchers/plugins/claude_session/health.sh:91`) uses the identical
`claude_session_switch_model` + `MODEL_SWITCH_LOCK` mechanism so a probe and a
task-model switch can never race each other. It runs on the standing model
and effort, and switches only when `config.json` sets
`session.health_probe_model`/`health_probe_effort` to something else. The
default was `haiku`/`low` until 2026-10-18. The CLI opens a "Change effort
level?" cache-miss confirm on `/effort` that the `PreModelSwitch` allow hook
does not skip (observed on CLI 2.1.302); the probe sat
behind it, and the switch-back keystrokes landed in the picker: its `Enter`
accepted "switch to low" and the `/model` back was lost, so every later turn,
Telegram included, ran on haiku (`tests/health_probe_model.sh`). Every probe
switch also re-read the whole conversation uncached on both models. Because
the probe posts on one scheduler tick and resolves (reply lands, or times out)
on a later one, the lock is acquired at post time and held across ticks via a
persistent fd (8, opened once by `claude_session_init`) rather than released
and reacquired - `_claude_session_release_probe_model` switches back to the
standing default and releases it on every resolution path (reply landed,
timed out, or the post itself failed).

Every switch types into the input box, so anything already sitting there
changes what the keystrokes mean. `_claude_session_accept_dialog` used to
answer the development-channels warning with `1` and then `Enter`, but `1`
alone selects and confirms. The Enter reached the REPL while a large
`--continue` resume was still loading and left a newline in the input box, so
the first `/model`/`/effort` after a spawn arrived as the plain prompt
`\n/model haiku` instead of a command: the switch never happened, and the
session read it as a request. 34 of 47 spawns from 2026-09-27 to 2026-10-08
leaked their first switch this way, and no leak happened anywhere else. One of
them, on 2026-09-29, made the session write `haiku` into
`state/telegram-model.txt`, so every respawn after it and every task without
its own `models.json` entry ran on haiku. The accept now sends `1` only
(`tests/accept_dialog.sh`). Diagnostic signature of a recurrence: a transcript
`user` record whose content is a bare `/model ...` or `/effort ...` string
instead of a `<command-name>` record.

# Adding a new task
1. Create the prompt file in `config/agents/` (or use a `command` for deterministic work).
2. Add an entry to `config/schedule.json` (name, cron, prompt_file OR command, enabled, model, effort).
3. That's it - the task whitelist is derived from `schedule.json`.

See `examples/content/` for the overlay layout, including a template for each
task type. `schedule.json` ships empty: a new install runs no tasks until you
add them.
