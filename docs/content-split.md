# Framework and content split
This repo (the framework) ships only generic scheduling/transport code and a
small set of behavior prompts. Operator content - `schedule.json`, `models.json`,
`config.json`, `secrets.json`, scheduled-task prompts (`agents/<task>.txt`), and
run-scripts (`scripts/*`) - lives in a separate `config/` git repo that you
create and control (see `examples/` in this repo for a starter layout). In
production it is bind-mounted at `/app/config` from a host clone (e.g.
`/opt/zoidberg-config`); on the dev machine a checked-out copy at `config/` fills
the same role. Content resolves through a `CONTENT_DIR` env, defaulting to
`${REPO_DIR}/config`.

Two helpers in `lib/common.sh` mediate the split:
- `content_path <relative>` - absolute path under `CONTENT_DIR` for operator
  content (`config.json`, `secrets.json`, `schedule.json`, `scripts/*`).
- `framework_prompt <name.txt>` - resolves a framework behavior prompt. A file
  at `${CONTENT_DIR}/agents/<name>.local.txt` is APPENDED to the shipped prompt
  at `${REPO_DIR}/agents/<name>.txt` (merged into `${STATE_DIR}/prompts/` and
  regenerated per call, so edits need no redeploy). This is the right slot for
  operator additions. A file at `${CONTENT_DIR}/agents/<name>.txt` still
  replaces the shipped prompt entirely (content-override-by-presence), but a
  full override shadows it forever: every later framework fix silently stops
  reaching that install, and only a manual diff reveals it. `.local` first,
  always. `prompt-sections.txt` is positional (line 1 is the attribution marker,
  `sed` takes the first match of each header) and takes no `.local`.

Dispatched `command`/`pre_check` tasks get an exported env contract
(`_export_task_env` in `watchers/plugins/cron.sh`): `CONTENT_DIR`, `APP_DIR`
(= `REPO_DIR`), `STATE_DIR`, `SKILLS_DIR`, `CONFIG_FILE`, `SECRETS_FILE`.
