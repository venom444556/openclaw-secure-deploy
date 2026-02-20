# ============================================================
# PGPClaw — Ephemeral Execution Runner
# Minimal image for sandboxed task execution.
# Run with: docker run --rm --read-only --network none ...
# ============================================================

FROM debian:bookworm-slim

# Non-root user
RUN groupadd -g 1000 runner && \
    useradd -u 1000 -g runner -m -s /bin/sh runner

# Minimal toolset — only what tasks actually need
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      git \
      python3 \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
