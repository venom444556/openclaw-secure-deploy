# ============================================================
# PGPClaw — OpenClaw Admin Policy (Secret Management)
# Used by store-secret.sh and rotate-secrets.sh only.
# Credentials stored in macOS Keychain, never on disk.
# ============================================================

# Full CRUD on the openclaw secrets path
path "secret/data/openclaw/*" {
  capabilities = ["create", "update", "read", "delete"]
}

# Read metadata (list secrets, check versions)
path "secret/metadata/openclaw/*" {
  capabilities = ["read", "list"]
}

# Allow token self-renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Deny everything else
path "*" {
  capabilities = ["deny"]
}
