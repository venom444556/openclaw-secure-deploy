# Post-Deploy: Adding Your API Key & Starting the Gateway

> All commands below assume you're in the `openclaw-secure-deploy/` directory.

## Required

1. Edit the env file:
   ```bash
   nano config/.env
   ```

2. Replace the placeholder on line 7:
   ```
   ANTHROPIC_API_KEY=sk-ant-YOUR_REAL_KEY_HERE
   ```

3. Set your gateway login password:
   ```
   OPENCLAW_AUTH_PASSWORD=your-strong-password-here
   ```

4. Set your Grafana dashboard password (use a DIFFERENT password than the gateway):
   ```
   GRAFANA_ADMIN_PASSWORD=a-different-strong-password
   ```

5. Start the gateway:
   ```bash
   source config/.env && openclaw gateway --port 18789
   ```

6. Verify it's working:
   ```bash
   curl http://localhost:18789/health
   ```

## Optional Keys (only if you use these channels)

- `OPENAI_API_KEY` — only if routing to OpenAI models
- `TELEGRAM_BOT_TOKEN` — for Telegram channel (see Telegram setup below)
- `DISCORD_BOT_TOKEN` — only if using Discord as a channel
- `SLACK_WEBHOOK_URL` — only if you want Slack alert notifications
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `BACKUP_S3_BUCKET` — only if you want offsite S3 backups

## Telegram Setup

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow the prompts to name it
3. Copy the bot token BotFather gives you
4. Paste it into `config/.env`:
   ```
   TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
   ```
5. Restart the gateway

## n8n (Workflow Automation)

n8n is included in the Docker stack for building automation workflows.

Start it:
```bash
docker compose -f docker/docker-compose.yml up -d n8n
```

Access at: http://localhost:5678

n8n will prompt you to create an account on first launch. Data is persisted in the `n8n_data` Docker volume.

To connect n8n to OpenClaw, use the HTTP Request node pointed at `http://host.docker.internal:18789` (or `http://localhost:18789` if using host networking).

## Backup Encryption

Add a strong passphrase for encrypted backups:
```bash
echo 'your-long-random-passphrase' > ~/.openclaw/config/backup-passphrase
chmod 600 ~/.openclaw/config/backup-passphrase
```

## Monitoring Stack

Already running:

| Service      | URL                    | Login                              |
|--------------|------------------------|------------------------------------|
| Prometheus   | http://localhost:9090  | No auth                            |
| Grafana      | http://localhost:3000  | admin / your GRAFANA_ADMIN_PASSWORD |
| Alertmanager | http://localhost:9093  | No auth                            |
| n8n          | http://localhost:5678  | Create account on first launch      |

To restart the monitoring stack:
```bash
docker compose -f docker/docker-compose.yml up -d prometheus grafana alertmanager n8n
```
