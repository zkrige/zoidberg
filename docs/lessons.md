# A system's own log is not a source
When diagnosing why the system did something, do not treat its own log line as
ground truth for a factual claim. The log can BE the symptom of the bug.

**Why:** on 2026-07-24 a scheduled task that parses a chat leaderboard logged
"not #1 for week 2026-W30" every day, and that log was quoted back as proof the
rule had worked correctly. The owner pushed back: "I was 10 points ahead
yesterday". Fetching the real leaderboard showed he was first by 12 points. The
upstream bot had changed its format from `<@id> — N pts` to plain names, the
parser matched 0 rows, and 0 rows renders as "not #1". The log reported what the
code concluded, not whether the conclusion was correct.

**How to apply:** verify the automation's INPUTS against the real external
source, the actual message or API response, not its logs or state.

## Validate a failure mode before designing for it
The health probe (420fc2b) posts a synthetic channel event and respawns the
session after two unanswered probes.

**Why:** "resuming a wedged conversation could resume the wedge" was asserted as
design rationale without reading the logs. The logs refuted it, and the
exception it justified would have wiped context daily. Every wedge respawn
between 2026-08-02 and 2026-08-13 fired at about 02:04 UTC, minutes after the
daily 02:00 UTC restart. `_HEALTH_PROBE_LAST` started at 0, so the first probe
raced the session's startup (dialog accept, MCP handshake), timed out at 25s,
and the probe 180s later landed strike two. Zero content-caused wedges have ever
been observed. Fixed in a996332 by arming a one-probe-interval grace in
`claude_session_spawn` (`tests/health_probe_grace.sh`).

**How to apply:** check the observed failures before writing code for a
hypothesised one.

## Scrubbing history needs a repo recreate
On 2026-07-24 this repo's history was squashed to a fresh root. A force-push
alone does NOT remove the old objects from GitHub: the pre-rewrite commits,
trees and blobs stayed retrievable through
`gh api repos/.../git/commits/<old-sha>` even after `git fetch <sha>` refused
them. Only deleting and recreating the repository, under the same name and URL
so no remote had to change, made every old SHA return 404 or 422.

## Renaming a host directory means migrating the volumes first
The compose project name derives from the directory, so renaming the directory
renames the named volumes. A fresh `wa-bridge-store` forces a WhatsApp QR
re-pair. Copy the volumes with a helper container before `compose up`.
