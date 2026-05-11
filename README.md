# ElevenLabs Telegram Bot

Telegram bot for managing ElevenLabs voice agents via n8n workflows.

## Stack

- **n8n** — automation workflows
- **MySQL 8** — user/agent/session storage
- **Cloudflare Tunnel** — HTTPS without port conflicts
- **ElevenLabs Conversational AI API** — agent management

## Setup

1. Copy `.env.example` to `.env` and fill in credentials
2. Run `schema.sql` against your MySQL instance
3. Import `workflow.json` into n8n
4. Configure n8n credentials: MySQL, Telegram, ElevenLabs HTTP Header Auth

## Database

See `schema.sql`. Key design decisions:

- `user_agents.id` (internal INT) is used in all callback_data — never the raw ElevenLabs agent ID
- Ownership verified via JOIN on every agent operation
- `action_logs` has no FK to users — audit trail survives user deletion
- FSM state stored in `user_sessions.current_action`

## Security

Every agent operation runs this ownership check before proceeding:

```sql
SELECT ua.id, ua.elevenlabs_agent_id, ua.agent_name
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.id = ?
  AND ua.is_active = 1;
```

Zero rows → deny + log to `action_logs` with `status='denied'`.

## Environment variables

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | From @BotFather |
| `ELEVENLABS_API_KEY` | From elevenlabs.io → Profile → API Keys |
| `MYSQL_*` | Database connection |
