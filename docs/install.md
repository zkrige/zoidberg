# Install is two stages

`install.sh` does only deterministic bootstrap: prerequisite detection (offered,
never forced), clone, seeding the overlay from `examples/content/`, creating the
mount points, and generating a random bridge key. It does not build, start, or
touch Telegram. `setup.sh run` drives the resumable sequence, and the `/setup`
skill (`.claude/skills/setup/SKILL.md`) runs in the operator's own Claude for
the judgment work: BotFather guidance, chat_id discovery through `getUpdates`,
config authoring, schedule authoring, the container build, the one-time
in-container OAuth, host cron entries, and end-to-end verification. Do not spawn
a second Claude on the host for this; the bot's own session authors the
schedule after the installer messages the owner to reply `/setup`.

Verification is mandatory, not optional. `docker/entrypoint.sh` hard-fails on
nothing, so a misconfigured install looks healthy while the session 401s
forever.
