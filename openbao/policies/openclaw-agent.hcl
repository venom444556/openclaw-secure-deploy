# ============================================================
# PGPClaw — OpenClaw Agent Policy (Least Privilege)
# The agent can ONLY read secrets. Nothing else.
# ============================================================

# Read secrets under the openclaw path only
path "secret/data/openclaw/*" {
  capabilities = ["read"]
}

# Allow the agent to renew its own token (extends TTL within max_ttl)
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Explicit deny on everything else
path "*" {
  capabilities = ["deny"]
}
