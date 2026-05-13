# ElevenLabs Telegram Bot

English | [Русский](README.ru.md)

Telegram bot for managing your own ElevenLabs Conversational AI voice agents. Each user registers their agents in the bot and edits their parameters (system prompt, welcome message, knowledge base) without ever opening the ElevenLabs dashboard.

## Stack

- **n8n** (self-hosted, US VPS) — orchestration. 49 nodes, one webhook trigger on Telegram
- **MySQL 8** — users, agents, FSM sessions, audit log
- **ElevenLabs Conversational AI API** — agent CRUD, knowledge base creation and attachment
- **Cloudflare Tunnel** — HTTPS into n8n without exposing ports on the VPS

## What the bot can do

| Command | What it does |
|---|---|
| `/start` | Registers the user in `users`, creates an empty session, opens the main menu |
| `/menu` | Shows the main menu (My agents + Add agent) |
| `/add` | Creates a new agent. The bot asks for a name, calls `POST /v1/convai/agents/create`, writes the row into `user_agents` |
| `/cancel` | Resets FSM state, returns to idle |
| `/help` | Prints help |

From the agent menu the user can: edit the system prompt, edit the welcome message, replace the knowledge base (upload text to `/v1/convai/knowledge-base`, then attach to the agent), switch between agents, delete.

Every operation that touches an agent goes through an **ownership check** — each modify request runs a JOIN `user_agents × users` on `telegram_user_id`, and if no row comes back, the action is logged as `denied` and the user gets a refusal. The raw `elevenlabs_agent_id` is never sent into Telegram `callback_data`; the internal `user_agents.id` is used instead.

## What's managed from the bot vs. from the ElevenLabs dashboard

The bot covers what shapes the agent's **content and behavior**: system prompt, welcome message, knowledge base. That's what the test task asked for.

Everything else stays in the ElevenLabs dashboard: choice of LLM model (GPT-4o, Gemini 2.0 Flash, Claude 3.5 Sonnet, custom_llm endpoint), voice selection, tools/functions, phone numbers, session configuration. All of it is reachable through the same ElevenLabs API and could be added to the bot if needed — `agent.prompt.llm` is patched via the same `PATCH /v1/convai/agents/{id}` already used here for the prompt.

## Architecture decisions

- **FSM lives in the DB, not in n8n memory.** `user_sessions.current_action` (`idle` / `awaiting_prompt` / `awaiting_welcome` / `awaiting_kb_text` / `awaiting_agent_name`) is the single source of truth. n8n can restart without losing any user's in-progress input.
- **`user_agents.id` (INT) goes into callback_data.** Raw ElevenLabs IDs never reach Telegram — that's both a privacy decision and a guard against forged callbacks.
- **`action_logs` has no FK on users.** The audit trail survives user deletion, which matters for incident review.
- **`/start: Upsert User` uses `INSERT … ON DUPLICATE KEY UPDATE`** on `telegram_user_id`. Idempotent — `/start` can be hit any number of times.

## Setup

1. Copy `.env.example` to `.env`, fill in the values
2. `mysql < schema.sql`
3. Import `workflow.json` into n8n (Workflows → Import)
4. Configure three n8n credentials:
   - **MySQL** — connects to `elevenlabs_telegram_bot`
   - **Telegram** — Bot Token from @BotFather
   - **HTTP Header Auth** for ElevenLabs — header `xi-api-key`, value is your ElevenLabs API key (needs `convai_*` scopes)
5. Attach the Telegram webhook to the `TG Trigger` node (n8n shows the URL once the workflow is activated)
6. Activate the workflow

## Environment variables

| Variable | Where it's used |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Direct Bot API call from the `LIST: Send` node (httpRequest) — workaround for an n8n Telegram node bug, see below |
| `ELEVENLABS_API_KEY` | Goes into the HTTP Header Auth credential as `xi-api-key` |
| `MYSQL_*` | MySQL credential |

On the n8n host, `$env.*` access in nodes requires the **`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`** flag (drop-in `/etc/systemd/system/n8n.service.d/env-access.conf`).

## Database

See `schema.sql`. Four tables:

- `users` — UNIQUE on `telegram_user_id`
- `user_agents` — UNIQUE `(user_id, elevenlabs_agent_id)`, soft-delete via `is_active`
- `user_sessions` — PK on `telegram_user_id`, ENUM for FSM state
- `action_logs` — append-only, no FKs, indexed by `action_type`, `status`, `created_at`

Every modify operation starts with this JOIN (`PROMPT: Get Agent (ownership)` and its welcome/kb siblings):

```sql
SELECT ua.id, ua.elevenlabs_agent_id, ua.agent_name
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.id = ?
  AND ua.is_active = 1;
```

Zero rows means the IF node `PROMPT: Agent found?` routes to `MSG: Cancel Update`, the session is reset, and `action_logs` gets a `denied` entry.

## n8n gotchas (what I learned the hard way)

### 1. Dynamic `inline_keyboard` is silently ignored by the Telegram node

`n8n-nodes-base.telegram@1.2` with `replyMarkup="inlineKeyboard"` plus a dynamic `inlineKeyboard.rows = ={{ $json.keyboard.map(...) }}` **drops the expression** and sends an empty `reply_markup` to Telegram. The node only reads fixedCollection values for that field; expressions aren't evaluated.

**Workaround:** for dynamic keyboards, bypass the node and call Bot API directly via `httpRequest`:
```
POST https://api.telegram.org/bot{{ $env.TELEGRAM_BOT_TOKEN }}/sendMessage
body: { chat_id, text, reply_markup: { inline_keyboard: [...] } }
```

The `LIST: Send` node uses this — it builds the keyboard for «My agents» after the user taps the menu button. Static keyboards (main menu, agent menu) stay on the native Telegram node, where no expression is needed.

### 2. IF v2 with strict typeValidation breaks on MySQL integer columns

A MySQL node returns `id` as a JavaScript number. If you set up an IF v2 condition with operator `exists`, type `"string"`, and `conditions.options.typeValidation: "strict"`, the node fails with:
```
NodeOperationError: Wrong type: '5' is a number but was expecting a string [condition 0, item 0]
```
Setting per-condition `typeValidation: "loose"` does **not** override this — n8n reads the parent `conditions.options.typeValidation`.

**Fix:** set `parameters.conditions.options.typeValidation: "loose"` **and** `parameters.looseTypeValidation: true` (both places, because the n8n editor surfaces one and the runtime checks the other). Applied to the `PROMPT: Agent found?` node.

### 3. MySQL node placeholders

Query parameters need `={{ $json.foo }}` (the `=` prefix matters) and `executeQuery` mode. Without the prefix n8n doesn't interpolate expressions into the SQL.

### 4. Webhook URL and Cloudflare Tunnel

Activating the Telegram webhook needs a public HTTPS endpoint. n8n generates a URL of the form `https://<n8n-host>/webhook/<id>`. Cloudflare Tunnel forwards the domain to `127.0.0.1:5678`. The webhook ID doesn't change across n8n restarts, so the Telegram subscription doesn't need to be re-registered.

## Repo layout

```
.
├── README.md            # this file (English)
├── README.ru.md         # Russian version
├── schema.sql           # MySQL DDL
├── workflow.json        # exported n8n workflow (49 nodes)
├── .env.example         # template for environment variables
└── .gitignore
```

## Status

Prod: n8n is active on a US VPS, workflow `ElevenLabs Voice Agent Bot` (`id: 72ad4b58019c4be3`) is `active=1`. As of the last commit, the DB has live agents created and exercised end-to-end: `create_agent` ×4, `edit_prompt`, `edit_welcome`, `edit_kb` — all success in `action_logs`.
