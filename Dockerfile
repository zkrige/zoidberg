ARG ENABLE_WHATSAPP=0

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
# Final image
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS final
ARG ENABLE_WHATSAPP=0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq curl git python3 python3-pip python3-venv \
    qpdf lsof procps xxd sqlite3 openssh-client ca-certificates \
    ffmpeg wget sudo tmux unzip \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# whisper for voice note transcription. Install CPU-only torch from the
# PyTorch CPU wheel index BEFORE openai-whisper: the default torch build pulls
# in ~2.9GB of NVIDIA CUDA libraries, which are dead weight on this ARM,
# no-GPU deploy target. Installing the CPU wheel first satisfies whisper's
# torch dependency so the CUDA variant is never resolved.
RUN pip3 install --break-system-packages --no-cache-dir --timeout=300 \
    --index-url https://download.pytorch.org/whl/cpu torch \
    && pip3 install --break-system-packages --no-cache-dir --timeout=300 openai-whisper

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
