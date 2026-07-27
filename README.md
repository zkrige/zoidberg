# Zoidberg

Your own Claude, running on your own hardware, that you talk to from Telegram
and that gets on with scheduled work while you are not looking.

It runs on your Claude subscription rather than metered API credit. That is the
whole reason it is built the way it is: one long-lived interactive session that
every message and scheduled task is fed into, instead of a new API process per
request. Leave it running all day without watching a meter.

It runs as a Docker container on any Linux box or a Mac. A single-board
computer such as a Raspberry Pi or Orange Pi is plenty; a Mac mini works
equally well.

## What you get

- **A Claude you message on Telegram.** Ask it things, hand it work, get
  answers back. It remembers the conversation.
- **Scheduled tasks.** Anything you can describe: a morning briefing, a report,
  a check that something is still up. Some need Claude to read and reason, some
  are just a script on a timer. Both are supported.
- **Optional WhatsApp triage**, off by default.

Nothing is scheduled when you install it. You tell it what you want, and it
writes that for you.

## Getting started

You need a Linux host or a Mac, and `curl`. Everything else the installer
offers to fetch for you: `apt-get` on Linux, Homebrew on macOS.

```bash
curl -fsSL https://raw.githubusercontent.com/zkrige/zoidberg/main/install.sh | bash
```

That is the whole install. It checks prerequisites, sets the framework up, then
builds and starts everything. It stops for you twice, both times for something
only you can do:

- **A bot token.** Create a bot with [@BotFather](https://t.me/BotFather) in
  Telegram (`/newbot`) and paste the token in. Then send your new bot a
  message so it can learn which chat is yours.
- **Signing in to Claude.** It prints a URL. Open it anywhere, approve, paste
  the code back. Your server needs no browser.

When it finishes, Zoidberg messages you on Telegram. Reply `/setup` and it will
ask what you want automated and write your schedule for you.

If anything is interrupted, `cd /opt/zoidberg && ./setup.sh run` picks up from
wherever it stopped. Provisioning a host now and configuring it later? Set
`SKIP_SETUP=1` and the installer stops once the filesystem is ready.

Want it somewhere other than `/opt`? Set `REPO_PATH` and nothing else changes:

```bash
curl -fsSL https://raw.githubusercontent.com/zkrige/zoidberg/main/install.sh | REPO_PATH=~/zoidberg bash
```

Your config and skills directories default to siblings of it, the installer
records all three in the repo's `.env`, and docker compose reads that. No file
needs editing. `CONTENT_PATH` and `SKILLS_PATH` move those two independently.

## Your stuff stays yours

This repo is the engine, and it is deliberately empty of opinions: no tasks, no
prompts about your life, no credentials. All of that lives in a separate
directory of your own at `/opt/zoidberg-config`, which the installer creates
and which is never part of this repo.

Keep it as a plain directory, or make it a private git repo if you want your
own config version-controlled and synced. Either works.

## Keeping it current

A cron job on the host checks git every five minutes and applies what it finds,
so pushing to your fork deploys it. Updates that only change code reload in
place; the bot keeps running.

## Why "Zoidberg"

[OpenClaw](https://github.com/openclaw/openclaw) is the lobster in this space:
a self-hosted personal AI assistant with a lobster mascot, and by some distance
the most-starred repository on GitHub. This does much the same job at a
fraction of the ambition, so it is also a crustacean, just a lesser one.

Dr. John A. Zoidberg is Futurama's Decapodian: lobster-adjacent, employed as a
doctor, not notably good at being one, and permanently
["the option nobody picked"](https://knowyourmeme.com/memes/futurama-zoidberg-why-not-zoidberg).

Needed a name. Why not Zoidberg?

## Documentation

| Document | Covers |
|----------|--------|
| `docs/ARCHITECTURE.md` | How it is built: components, transport, the plugin and feature contracts |
| `docs/features/README.md` | Optional features and how to add one |
| `examples/README.md` | What goes in your config directory |
| `CLAUDE.md` | Reference for working on Zoidberg itself |

## License

MIT. See `LICENSE`.
