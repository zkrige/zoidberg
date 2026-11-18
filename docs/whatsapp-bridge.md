# WhatsApp bridge

The bridge (whatsmeow-based, `docker/whatsapp-bridge-src/`) was re-vendored from
upstream `FelixIsaac/whatsapp-mcp-extended` at tag v0.3.0 (commit de0bd63) on
2026-07-08. Upstream force-pushes its history, so always pin a SHA or a tag,
never track a branch. Provenance and the local patch list are in
`docker/whatsapp-bridge-src/UPSTREAM.md`, which makes the next convergence
mechanical: re-vendor pristine, then re-apply the listed patches (the flag shim
for `-store-dir` and `-listen`, the `/tmp/whatsapp-media` download dir, and the
`AUTO_DOWNLOAD_MEDIA` gate defaulting off).

`docker/whatsapp-mcp-server` is deliberately NOT converged. It is a structural
rewrite, a `lib/` REST-client split against upstream's 2359-line direct-DB
monolith. Treat it as our own fork and port individual upstream tools on demand.

## Webhook dispatch
Instant dispatch (webhook to the `whatsapp.sh` listener to
`lib/whatsapp-dispatch.sh`) had never worked until 2026-07-08. `webhook_logs`
had zero rows and `could not reach bridge API` appeared 113 times in
`automations.log`. Two independent causes:
1. The plugin's `GET` and `POST /api/webhooks` curls sent no `X-API-Key`, and
   the bridge has enforced auth since the Docker migration. Fixed in e736792.
2. Upstream v0.3.0 added an SSRF guard rejecting webhook URLs on private or
   loopback addresses, and our listener is `127.0.0.1` in the same container by
   design. Fixed with `export DISABLE_SSRF_CHECK=true` in
   `docker/entrypoint.sh:70`, upstream's own escape hatch
   (`internal/webhook/validation.go:60`).

The plugin conflates 401 with unreachable (`curl -f`), so the failure was silent
for months. Verify any bridge change by checking for `webhook_logs` ROWS, not
the registration log line. An end-to-end test needs a self-chat message from a
DIFFERENT linked device: a message sent through the bridge's own `/api/send`
does not loop back through its inbound handler.

## Re-pairing
Two failure modes show up:
1. `[Client WARN] Keepalive timed out`, then `KeepAlive: 3 consecutive failures,
   forcing disconnect+reconnect`, then `lookup web.whatsapp.com: no such host`,
   then `Disconnecting...`. DNS broke.
2. `Got 401: logged out from another device connect failure, sending LoggedOut
   event and deleting session`, then `Device logged out - please scan QR code to
   log in again`. The session was invalidated server-side, by another device
   claiming the slot or by expiry. The bridge keeps running but the session file
   under `store/` is purged.

The bridge does not fall back to QR pairing mid-process after a 401. It needs a
fresh process start with no valid session in `store/` before the QR prints. The
entrypoint starts it as a background process, so if it dies the container stays
up and nothing respawns it. If a restart reconnects and then immediately hits
the 401 again, kill and restart once more; the second start prints the QR.

WhatsApp allows four linked devices and each bridge takes one slot, so two
bridges can stay paired at the same time without kicking each other.
