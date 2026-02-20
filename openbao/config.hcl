# ============================================================
# PGPClaw — OpenBao Server Configuration
# Loopback only. TLS disabled (Tailscale handles transport).
# ============================================================

disable_mlock = true
ui            = false

storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

# Audit log — every secret access is recorded
# Enabled via bootstrap-bao.sh after init
