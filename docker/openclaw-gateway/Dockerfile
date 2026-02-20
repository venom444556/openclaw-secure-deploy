# ============================================================
# PGPClaw — OpenClaw Gateway Image
#
# Custom Docker image packaging the OpenClaw npm package into
# a hardened container with pinned version, non-root user,
# and minimal attack surface.
#
# Build:
#   docker compose -f docker/docker-compose.yml --profile build build
#
# The gateway reads secrets from environment variables injected
# by start-gateway.sh (fetched from OpenBao). No secrets are
# baked into this image.
# ============================================================

FROM node:22-slim

# Install minimal runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      git \
      tini \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Pin OpenClaw version — no :latest tags
ARG OPENCLAW_VERSION=2026.2.19-2
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" && \
    npm cache clean --force

# Create non-root user (1001:1001) matching docker-compose user directive
RUN groupadd -g 1001 openclaw && \
    useradd -u 1001 -g openclaw -m -s /bin/sh openclaw

# Pre-create state directories with correct ownership
RUN mkdir -p /home/openclaw/.openclaw/logs \
             /home/openclaw/.openclaw/sessions \
             /home/openclaw/.openclaw/agents \
             /home/openclaw/.openclaw/credentials \
             /home/openclaw/.openclaw/backups \
             /home/openclaw/.openclaw/config \
             /home/openclaw/.openclaw/workspace && \
    chown -R openclaw:openclaw /home/openclaw/.openclaw && \
    chmod 700 /home/openclaw/.openclaw/credentials

USER openclaw
WORKDIR /home/openclaw

# Use tini as PID 1 for proper signal forwarding and zombie reaping
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["openclaw", "gateway", "run"]
