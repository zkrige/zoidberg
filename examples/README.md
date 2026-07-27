# Example content overlay

This directory (`examples/content/`) is a minimal, working sample of the
**content overlay** the framework expects at `config/`. It shows the shape of
every file the scheduler and plugins read at runtime, with generic
placeholder values instead of real credentials or schedules.

## Framework vs. content

This repo (`Zoidberg`) is the generic engine: the
scheduler, plugins, transport, and a handful of framework behavior prompts
under `agents/` (guardrails, telegram-system, prompt-sections). It has no
opinion about what tasks you run, what accounts you use, or what your bot
should say.

Everything specific to one operator's instance - the task schedule, task
prompts, config, secrets, and any run-scripts - lives in a separate **content
overlay**. In production that overlay is its own private git repo that you
create and control; the framework never needs to see its contents to work.

## How the framework finds your overlay

Resolution happens through `CONTENT_DIR`, defined in `lib/common.sh`:

```bash
: "${CONTENT_DIR:=${REPO_DIR}/config}"
content_path() { printf '%s/%s' "$CONTENT_DIR" "$1"; }
```

- **Locally**, `CONTENT_DIR` is unset, so it defaults to `${REPO_DIR}/config`
  - a `config/` directory (or git submodule) checked out next to the
  framework code.
- **In Docker**, `docker-compose.yml` bind-mounts your overlay's host path
  into the container and sets `CONTENT_DIR=/app/config`:

  ```yaml
  volumes:
    - ${CONTENT_PATH:-../zoidberg-config}:/app/config
  environment:
    - CONTENT_DIR=/app/config
  ```

  The default is relative, and compose resolves it against the directory the
  compose file is in, so an overlay cloned beside the framework repo just
  works. `install.sh` and `setup.sh env` write the real `CONTENT_PATH` into
  the repo's `.env`, which compose reads; point it anywhere and the container
  still sees the overlay at `/app/config`.

Everything that reads operator content goes through `content_path()`:
`load_config` reads `content_path config.json`, `load_secrets` reads
`content_path secrets.json`, `is_allowed_task` reads
`content_path schedule.json`, and scheduled `command` entries reference
scripts under `"$CONTENT_DIR/scripts/..."`.

### Framework prompts can be overridden too

`framework_prompt <name.txt>` (also in `lib/common.sh`) lets your overlay
override a shipped framework behavior prompt without forking the framework
repo: if `${CONTENT_DIR}/agents/<name>` exists it wins, otherwise the
framework falls back to its own `agents/<name>`.

## Setting up your own overlay

1. Create a new private repo for your content (e.g. `my-claude-config`).
2. Copy the layout from `examples/content/` into it: `schedule.json`,
   `config.example.json` -> `config.json`, `secrets.example.json` ->
   `secrets.json`, `agents/`, `scripts/`.
3. Fill in `config.json` and `secrets.json` with your real values. Both are
   gitignored in the framework repo's own `config/` submodule for the same
   reason - never commit secrets to a shared or public repo.
4. Point the framework at it:
   - **Local dev**: clone/symlink your overlay to `config/` next to the
     framework repo (or export `CONTENT_DIR` to wherever it lives).
   - **Docker**: set `CONTENT_PATH=/path/to/your-overlay` (or edit
     `docker-compose.yml`'s default) before `docker compose up`.
5. Add tasks by creating a prompt file under `agents/` (or a script under
   `scripts/` for deterministic work) and an entry in `schedule.json`, which
   starts empty. The two supported task shapes are `prompt_file` (dispatched to
   the Claude session) and `command` (run directly, no Claude reasoning
   involved); `agents/example-prompt.txt` and `scripts/example-command.sh` are
   templates for each. Nothing is scheduled until you schedule it.

## Files in this example

| File | Purpose |
|------|---------|
| `content/schedule.json` | Task schedule. Ships with an empty `tasks` array: a new install runs nothing until you add something |
| `content/config.example.json` | Non-secret config template (endpoints, workspace names, per-feature settings) |
| `content/secrets.example.json` | Secret template (bot tokens, credentials) - copy to `secrets.json`, never commit the real file |
| `content/agents/example-prompt.txt` | Template for a task prompt dispatched to the Claude session. Not scheduled |
| `content/scripts/example-command.sh` | Template for a deterministic command task, reading config via the `CONFIG_FILE`/`CONTENT_DIR` contract. Not scheduled |
