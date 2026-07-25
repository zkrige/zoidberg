# Vendored: whatsapp-bridge

- Upstream: https://github.com/FelixIsaac/whatsapp-mcp-extended.git
- Pinned commit: `de0bd63bf948270269ce27da934b2a2ed8998d2a`
- Tag: `v0.3.0`
- Vendored: 2026-07-08
- Source subtree: `whatsapp-bridge/` (copied to the top level of this directory)

Upstream force-pushes its branches, so always pin to the full commit SHA above, not to a branch or a mutable tag.

## Re-vendor

```
git archive de0bd63bf948270269ce27da934b2a2ed8998d2a whatsapp-bridge \
  | tar -x --strip-components=1 -C docker/whatsapp-bridge-src
```

Then re-apply the local patches below on top.

## Local patches applied on top of pristine upstream

Each patch is a separate commit after the pristine-vendor commit.

1. `bridge: restore -store-dir/-listen flags for container entrypoint`
   `main.go`: add `-store-dir` (chdir, create if missing) and `-listen host:port`
   (overrides `cfg.APIBindHost`/`cfg.APIPort`) so `docker/entrypoint.sh` can run
   `whatsapp-bridge --store-dir /opt/whatsapp-bridge-store --listen 0.0.0.0:8080`.
   Upstream defaults to `127.0.0.1:8080` with no flags.

2. `bridge: write on-demand media downloads to /tmp/whatsapp-media`
   `internal/api/download.go`: relocate the on-demand download output base dir
   from `store/media/` (persistent volume) to `/tmp/whatsapp-media/`.

3. `bridge: gate auto media download behind AUTO_DOWNLOAD_MEDIA (default off)`
   `internal/whatsapp/handlers.go`: the unconditional auto-download of every
   inbound media to the store volume is gated behind `AUTO_DOWNLOAD_MEDIA`
   (truthy `1`/`true`), default off.

Note: the outgoing document `FileName` (from the media path basename) is already
set upstream via `documentFileName()` in `internal/whatsapp/messages.go`, so no
separate patch is needed for it.
