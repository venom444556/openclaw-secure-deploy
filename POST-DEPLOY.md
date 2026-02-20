# Post-Deploy: Storing Secrets & Starting PGPClaw

> All commands assume you're in the pgpclaw repository directory and have run `./scripts/setup.sh`.

## Step 1: Store Your API Keys in OpenBao

PGPClaw does not use `.env` files for secrets. All API keys are stored in OpenBao.

```bash
# Required: Anthropic API key
./openbao/scripts/store-secret.sh anthropic-api-key sk-ant-YOUR-KEY-HERE

# Optional: OpenAI (if routing to OpenAI models)
./openbao/scripts/store-secret.sh openai-api-key sk-YOUR-KEY-HERE

# Optional: Telegram bot token
./openbao/scripts/store-secret.sh telegram-bot-token 123456789:ABCdefGHIjklMNOpqrsTUVwxyz

# Optional: Discord bot token
./openbao/scripts/store-secret.sh discord-bot-token YOUR-DISCORD-TOKEN

# Required: Gateway auth password
./openbao/scripts/store-secret.sh openclaw-auth-password your-strong-password

# Required (if monitoring profile): Grafana admin password
./openbao/scripts/store-secret.sh grafana-admin-password a-different-password
```

**Tip:** If you omit the value, the script will prompt you interactively (value won't appear in shell history).

```bash
./openbao/scripts/store-secret.sh anthropic-api-key
# Enter value for 'anthropic-api-key': [hidden input]
```

## Step 2: Start the Gateway

```bash
# Core profile (OpenBao + Gateway)
./scripts/start-gateway.sh core

# Or full profile (everything)
./scripts/start-gateway.sh full
```

The start script will:
1. Verify OpenBao is running and unsealed
2. Authenticate via AppRole (credentials from Keychain)
3. Fetch all secrets from OpenBao
4. Export to environment variables
5. Start Docker Compose with the selected profile
6. Revoke the OpenBao token

## Step 3: Verify

```bash
# Gateway health
curl http://localhost:18789/health

# OpenBao status
bao status

# All running containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

## Step 4: Configure OpenClaw

Edit the OpenClaw config to set your allowlists:

```bash
nano ~/.openclaw/openclaw.json
```

Key settings:
- `channels.whatsapp.allowFrom` — Your phone numbers
- `channels.telegram.allowFrom` — Your Telegram user IDs
- `api.costControl.notify` — Your alert email

## Optional: Set Up OAuth Integrations (oauth/full profile)

If you started with `--profile oauth` or `--profile full`:

1. Open the Nango dashboard: http://localhost:3003

2. Register OAuth apps for each provider you want:

   | Provider | Console URL |
   |----------|-------------|
   | Gmail / Google Drive | https://console.cloud.google.com/apis/credentials |
   | GitHub | https://github.com/settings/developers |
   | Notion | https://www.notion.so/my-integrations |
   | Slack | https://api.slack.com/apps |

3. In each provider's console:
   - Create an OAuth app
   - Set redirect URI to: `http://localhost:3003/oauth/callback`
   - Copy the Client ID and Client Secret

4. In the Nango dashboard:
   - Add the provider
   - Paste Client ID and Client Secret
   - Authorize the connection

## Optional: Telegram Bot Setup

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow the prompts
3. Copy the bot token
4. Store it:
   ```bash
   ./openbao/scripts/store-secret.sh telegram-bot-token YOUR-TOKEN
   ```
5. Restart: `./scripts/start-gateway.sh`

## Optional: n8n Workflows (monitoring/full profile)

Access n8n at: http://localhost:5678

n8n will prompt you to create an account on first launch. To connect n8n to OpenClaw, use the HTTP Request node pointed at `http://host.docker.internal:18789`.

## Backup Encryption

For encrypted backups, set up either:

**GPG (recommended):**
```bash
export GPG_RECIPIENT="your@email.com"
./scripts/backup.sh
```

**AES passphrase (fallback):**
```bash
echo 'your-long-random-passphrase' > ~/.openclaw/config/backup-passphrase
chmod 600 ~/.openclaw/config/backup-passphrase
./scripts/backup.sh
```

## Monitoring (monitoring/full profile)

| Service | URL | Login |
|---------|-----|-------|
| Prometheus | http://localhost:9090 | No auth |
| Grafana | http://localhost:3000 | admin / (password from OpenBao) |
| Alertmanager | http://localhost:9093 | No auth |
| n8n | http://localhost:5678 | Create on first launch |

### Alerts configured:
- API cost spikes (hourly and projected monthly)
- Auth failures (brute-force detection)
- Gateway down
- Sandbox container failures
- **OpenBao sealed** (critical)
- **OpenBao unreachable** (critical)
- **OpenBao high auth failures** (warning)
- **OpenBao lease accumulation** (warning)
- **Nango down** (warning)

## Incident Response Cheat Sheet

```bash
./scripts/incident-response.sh bao-seal         # Seal vault
./scripts/incident-response.sh nango-revoke      # Revoke OAuth
./scripts/incident-response.sh compromised-key   # Key leaked
./scripts/incident-response.sh runaway-cost      # Cost runaway
./scripts/incident-response.sh full-lockdown     # Nuclear option
./scripts/incident-response.sh restore           # Bring it back
```
