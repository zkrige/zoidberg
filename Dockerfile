ARG ENABLE_WHATSAPP=0
ARG ENABLE_WHISPER=1
ARG WHISPER_MODEL=base
ARG WHISPER_NATIVE=0

# -----------------------------------------------------------------------------
# WhatsApp bridge + MCP server payload
#
# A `COPY` cannot be made conditional inside a single build stage, so instead
# we build two candidate "payload" stages - one (`whatsapp-payload-1`) that
# actually installs the Go toolchain + gcc, compiles the bridge binary, and
# stages the MCP server source; and one (`whatsapp-payload-0`) that's an empty
# stand-in. `FROM whatsapp-payload-${ENABLE_WHATSAPP} AS whatsapp-payload`
# resolves at parse time to exactly one of them, and Docker only builds the
# stage that ends up as an actual dependency of the final image. With the
# default ENABLE_WHATSAPP=0, `whatsapp-payload-1` (and everything in it: Go,
# gcc, the bridge/mcp-server source COPYs) is never built and none of it
# touches the final image; only `--build-arg ENABLE_WHATSAPP=1` pulls it in.
# The Go toolchain and gcc never appear in the final stage either way - only
# the compiled binary + mcp-server source are copied out of this stage below.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS whatsapp-payload-1
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
# Go (latest stable) - build-time only, discarded once the binary is built
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://go.dev/dl/go1.26.2.linux-${ARCH}.tar.gz" -O /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
COPY docker/whatsapp-bridge-src/ /src/whatsapp-bridge-src/
RUN mkdir -p /out && \
    cd /src/whatsapp-bridge-src && \
    if [ -f go.mod ]; then CGO_ENABLED=1 go build -o /out/whatsapp-bridge .; fi
COPY docker/whatsapp-mcp-server/ /out/whatsapp-mcp-server/

FROM debian:bookworm-slim AS whatsapp-payload-0
RUN mkdir -p /out

FROM whatsapp-payload-${ENABLE_WHATSAPP} AS whatsapp-payload

# -----------------------------------------------------------------------------
# whisper.cpp payload
#
# Voice-note transcription, built from source and gated with the same two-stage
# trick as the WhatsApp payload above: `--build-arg ENABLE_WHISPER=0` swaps in
# the empty stand-in, so nothing whisper-related reaches the final image. It
# defaults to 1 because the Telegram and WhatsApp plugins both hand audio to
# `transcribe`; turn it off only if you never send voice notes. Note that the
# skipped stage is only skipped under BuildKit - the classic builder builds
# every stage regardless, so on a host without buildx the gate keeps the image
# clean but does not save the compile.
#
# whisper.cpp replaced the openai-whisper Python package, which dragged in a
# 639MB torch (1.1GB of dist-packages all told) to run the same models far
# slower. Measured here on an RK3588 (8 threads, 60s clip), openai-whisper vs
# this stage: base 89s -> 16.3s at the defaults below, or 8.6s with
# WHISPER_NATIVE=1. Those are one board's numbers, not a promise, which is why
# the model and the tuning are build args rather than fixed choices.
#
# WHISPER_MODEL is any name `download-ggml-model.sh` accepts (tiny, base,
# small, medium, large-v3-turbo, and the English-only `.en` variants, which are
# more accurate than their multilingual namesake but only transcribe English).
# The default `base` is multilingual and ~142MB, comfortable on modest
# hardware. Faster boards can afford `small.en` (~488MB) or better.
#
# WHISPER_NATIVE maps to ggml's GGML_NATIVE, and it is a portability/speed
# trade, worth about 2x on the reference board. The default 0 targets the
# architecture baseline, so the image runs on any host of that arch. Setting it
# to 1 compiles -mcpu=native against the BUILD host's exact CPU: correct for
# the normal deploy here, where `docker compose up -d --build` runs on the same
# machine as the container, and wrong the moment that image is moved to a
# different CPU, where it will fault rather than run slowly.
#
# Built static (BUILD_SHARED_LIBS=OFF) so the final stage needs one binary and
# no libwhisper/libggml beside it. The toolchain never leaves this stage.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS whisper-payload-1
ARG WHISPER_MODEL
ARG WHISPER_NATIVE
# curl is not optional here: download-ggml-model.sh needs wget2, curl or wget
# and exits non-zero with "Either wget2, curl, or wget is required" without one.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch v1.9.2 \
      https://github.com/ggml-org/whisper.cpp /src/whisper.cpp \
    && cd /src/whisper.cpp \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
         -DGGML_NATIVE="$([ "${WHISPER_NATIVE}" = "1" ] && echo ON || echo OFF)" \
         -DWHISPER_BUILD_TESTS=OFF \
    && cmake --build build -j"$(nproc)" --config Release --target whisper-cli \
    && sh ./models/download-ggml-model.sh "${WHISPER_MODEL}" \
    && mkdir -p /out \
    && cp build/bin/whisper-cli /out/whisper-cli \
    && cp "models/ggml-${WHISPER_MODEL}.bin" /out/model.bin

FROM debian:bookworm-slim AS whisper-payload-0
RUN mkdir -p /out

FROM whisper-payload-${ENABLE_WHISPER} AS whisper-payload

# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS final
ARG ENABLE_WHATSAPP=0
ARG ENABLE_WHISPER=1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq curl git python3 python3-pip python3-venv \
    qpdf lsof procps xxd sqlite3 openssh-client ca-certificates \
    ffmpeg wget sudo tmux unzip libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Playwright MCP server - gives the interactive session a real headless
# browser (navigate, click, fill forms, screenshot) for sites that need a
# login rather than plain WebFetch. Browsers are baked into the image at
# PLAYWRIGHT_BROWSERS_PATH (instead of downloaded lazily per-container) and
# made world-readable so the non-root `claude` user can launch them.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g @playwright/mcp playwright \
    && playwright install --with-deps chromium \
    && chmod -R a+rX /opt/ms-playwright

# whisper.cpp binary + model, built in the whisper-payload stage above (empty
# when ENABLE_WHISPER=0). `transcribe <audio>` is the only entry point: it
# resamples to the 16kHz mono WAV whisper.cpp needs and prints the transcript
# to stdout. The wrapper is installed either way and exits non-zero with a
# build hint when the binary is absent, so a disabled build fails loudly at the
# call site instead of looking like a broken transcription.
ENV WHISPER_MODEL=/opt/whisper/model.bin
COPY --from=whisper-payload /out/ /tmp/whisper-payload/
COPY docker/transcribe /usr/local/bin/transcribe
RUN if [ -f /tmp/whisper-payload/whisper-cli ]; then \
      mv /tmp/whisper-payload/whisper-cli /usr/local/bin/whisper-cli && \
      mkdir -p /opt/whisper && \
      mv /tmp/whisper-payload/model.bin /opt/whisper/model.bin; \
    fi && \
    rm -rf /tmp/whisper-payload && \
    chmod +x /usr/local/bin/transcribe

# uv (Python package manager) - only needed for the WhatsApp MCP server, which
# is invoked at runtime via `uv run main.py`, so (unlike the Go bridge) it
# must persist in the final image rather than just at build time. Gated on
# ENABLE_WHATSAPP: the layer still runs for the default build, but the shell
# conditional makes it a no-op, so nothing is downloaded or installed.
RUN if [ "$ENABLE_WHATSAPP" = "1" ]; then \
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    fi

# WhatsApp bridge binary + MCP server source, built in the whatsapp-payload
# stage above (empty when ENABLE_WHATSAPP=0, the default). Unpack whatever
# payload stage produced, then sync the MCP server's deps if it's present.
COPY --from=whatsapp-payload /out/ /tmp/whatsapp-payload/
RUN if [ -f /tmp/whatsapp-payload/whatsapp-bridge ]; then \
      mv /tmp/whatsapp-payload/whatsapp-bridge /usr/local/bin/whatsapp-bridge; \
    fi && \
    if [ -d /tmp/whatsapp-payload/whatsapp-mcp-server ]; then \
      mv /tmp/whatsapp-payload/whatsapp-mcp-server /opt/whatsapp-mcp-server && \
      cd /opt/whatsapp-mcp-server && \
      if [ -f pyproject.toml ]; then uv sync; fi; \
    fi && \
    rm -rf /tmp/whatsapp-payload

# Create non-root user
RUN useradd -m -s /bin/bash claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Claude CLI (install as claude user)
USER claude
ENV HOME=/home/claude
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh && bash /tmp/claude-install.sh && rm /tmp/claude-install.sh
ENV PATH="/home/claude/.local/bin:${PATH}"

# Bun (for bot-channel MCP server and other JS plugins)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/claude/.bun/bin:${PATH}"

# SSH config for git remotes
USER root
RUN mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh
COPY docker/ssh-config /home/claude/.ssh/config
RUN chmod 600 /home/claude/.ssh/config && chown -R claude:claude /home/claude/.ssh

WORKDIR /app
COPY . /app
RUN chown -R claude:claude /app && \
    if [ -d /opt/whatsapp-mcp-server ]; then chown -R claude:claude /opt/whatsapp-mcp-server; fi

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER claude
ENTRYPOINT ["/entrypoint.sh"]
