# ElevenLabs Telegram Bot

English | [Русский](README.ru.md)

A Telegram bot for managing your own ElevenLabs voice agents. Talk to it by voice or text in plain language. The bot figures out which agent you mean and what to change, then calls the ElevenLabs API.

Built as the test task for the Automation Developer position at profichat.net.

## Demo

Bot: [t.me/northbridge_ai_bot](https://t.me/northbridge_ai_bot)

`/start`, then either pick an agent from the menu or just write or say what you want:

- "update testgolden welcome to Hello world"
- "у Тор поменяй промпт на дружелюбный ассистент"
- "добавь в базу знаний sdfsd: компания основана в 2020 году"

## Stack

- n8n — workflow orchestration, native AI Agent (LangChain) pattern
- Google Gemini 2.5 Flash — language model for the agent, and speech-to-text for voice
- MySQL 8 — users, agents, sessions, audit log
- ElevenLabs Conversational AI API
- Telegram Bot API
- Cloudflare Tunnel for the webhook

## Architecture

The test task splits the UX in two:

- §2 "When a user sends messages": modify prompt, welcome, knowledge base.
- §4 "From the Telegram bot menu": view agents, select an agent.

Implemented exactly that way. Buttons handle navigation. Text and voice handle modifications via the AI Agent.

```
Telegram update
  ├─ callback_query  → menu chain   (LIST, SELECT, ADD)
  └─ message         → AI Agent chain (5 tools)
```

### AI Agent chain

```
Telegram Trigger
  → Parse Update (normalize, detect voice)
  → MSG: Route (filter out /commands)
  → TXT: Get Session → TXT: Route FSM (skip if mid-FSM, otherwise → AI)
  → AI: Get User Agents (MySQL: this user's agents)
  → AI: Is Voice?
       ├ voice → Get File Meta → Download → Encode → Transcribe (Gemini STT)
       └ text  → pass through
  → Build Agent Context (build system prompt with the user's agent list)
  → AI Agent (@n8n/n8n-nodes-langchain.agent v3.1)
       ├─ Google Gemini Chat Model           (ai_languageModel)
       ├─ Simple Memory  sessionKey=chat_id  (ai_memory)
       └─ 5 Code Tools                        (ai_tool):
           get_agent_config
           update_agent_prompt
           update_agent_welcome
           create_knowledge_doc
           attach_knowledge_to_agent
  → Send Agent Reply
```

43 nodes total.

### Why native AI Agent

The first version parsed intent by hand: HTTP to Gemini, Code node to parse JSON, Switch on action. It worked, but it was n8n hosting JavaScript, not n8n. Rewrote it as the native pattern: AI Agent with sub-node connections (`ai_languageModel`, `ai_memory`, `ai_tool`). Each tool declares an explicit JSON `inputSchema`, so Gemini emits well-formed function calls.

## Security (§3)

Two layers.

Menu reads run a JOIN `user_agents × users ON u.id = ua.user_id WHERE telegram_user_id = ?`. Zero rows means the agent never appears in the list. Inline-keyboard `callback_data` carries the internal `user_agents.id`, never the raw ElevenLabs id, so callbacks can't be forged with someone else's id.

For the AI Agent path, `Build Agent Context` reads the user's agents from MySQL before the agent runs and embeds them in the system prompt. Gemini only sees the user's own ids and has no way to reference an agent it doesn't see. Tool parameters are typed via JSON Schema, so the model can't drop in a foreign id.

The `action_logs` table is an append-only audit trail with `success`, `error`, `denied` rows.

## Database

See `schema.sql`. Four tables.

| Table | Purpose |
|---|---|
| `users` | Telegram users, UNIQUE on `telegram_user_id` |
| `user_agents` | Links users to ElevenLabs agents. UNIQUE `(user_id, elevenlabs_agent_id)`. Soft delete via `is_active` |
| `user_sessions` | FSM state for the `/add` flow (asking the user for the new agent's name). Everything else is stateless |
| `action_logs` | Append-only audit log |

Ownership query on every menu read:

```sql
SELECT ua.id, ua.agent_name, ua.elevenlabs_agent_id
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.is_active = 1
ORDER BY ua.created_at DESC;
```

## Tools (the 5 capabilities given to Gemini)

Each `toolCode` node declares an explicit `inputSchema` and calls ElevenLabs from JavaScript.

| Tool | Method | Endpoint | Inputs |
|---|---|---|---|
| `get_agent_config` | GET | `/v1/convai/agents/{agentId}` | `agentId` |
| `update_agent_prompt` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `newPrompt` |
| `update_agent_welcome` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `newFirstMessage` |
| `create_knowledge_doc` | POST | `/v1/convai/knowledge-base/text` | `docName`, `docText` |
| `attach_knowledge_to_agent` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `docId`, `docName` |

For knowledge-base updates the agent calls `create_knowledge_doc` first to get a doc id, then `attach_knowledge_to_agent` to wire it up. Gemini handles the dependency between the two calls.

## Setup

1. Copy `.env.example` to `.env`, fill values.
2. `mysql < schema.sql`.
3. Import `workflow.json` into n8n.
4. Configure four n8n credentials:
   - MySQL pointing at `elevenlabs_telegram_bot`
   - Telegram with the bot token from @BotFather
   - HTTP Header Auth for ElevenLabs, header `xi-api-key`, value = ElevenLabs key with `convai_*` scopes
   - Google Palm API for the Gemini Chat Model sub-node, key from Google AI Studio
5. Attach the Telegram webhook to the `TG Trigger` node (n8n shows the URL once you activate the workflow).
6. Activate the workflow.

## Environment variables

n8n needs these on the host (we set them via a systemd drop-in):

| Variable | Used by |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` | enables `$env.*` in Code / HTTP nodes |
| `N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true` | enables langchain tool usage |
| `TELEGRAM_BOT_TOKEN` | `LIST: Send` (direct Bot API for the dynamic inline keyboard) |
| `ELEVENLABS_API_KEY` | the 5 Code Tools |
| `GOOGLE_API_KEY` | `AI: Transcribe` (Gemini STT HTTP call) |

## n8n gotchas hit while building this

Non-obvious things worth knowing if you reuse parts of this workflow.

1. `toolHttpRequest` v1.1 has a supplyData/execute mismatch in n8n 2.19.5. The Agent runtime calls `.execute()`, the node only has `.supplyData()`. Workaround: use `toolCode` v1.3 with an explicit `inputSchema` and call `this.helpers.httpRequest` inline.
2. `$helpers` is not in the task-runner sandbox. Use `this.helpers.getBinaryDataBuffer(0, 'data')` for binary access. `N8N_RUNNERS_ENABLED=false` does not actually disable the runner in 2.19.5.
3. `require('mysql2/promise')` is blocked even with `NODE_FUNCTION_ALLOW_EXTERNAL=mysql2`. The langchain tool sandbox does not honor that flag. For MySQL inside a tool, expose it via a webhook sub-workflow instead.
4. `$fromAI()` in `toolHttpRequest` does not produce well-formed Gemini function declarations in this version (empty keys in `parameters.properties` → 400 from Gemini). Use literal `{placeholder}` with `placeholderDefinitions`, or move to `toolCode` with `inputSchema`.
5. Switch routing is by case index, not by `outputKey`. When you rewrite a Switch's rules, every connection must be removed and re-added at the right `sourceIndex`. Auto-sanitization doesn't fix this.
6. Switch `leftValue` is context-aware. If a Switch's input comes from node B but you want to route on a field from node A, write `$('A').item.json.field`. `$json` looks at whatever fed the Switch.
7. Dynamic `inline_keyboard` in `n8n-nodes-base.telegram@1.2` silently ignores expressions on `inlineKeyboard.rows`. For the agent-list keyboard this workflow bypasses the node and posts to the Bot API directly with `$env.TELEGRAM_BOT_TOKEN`.
8. IF v2 with strict `typeValidation` rejects integer columns from MySQL (the `id` comes back as a JS number). Set both `parameters.conditions.options.typeValidation: "loose"` and `parameters.looseTypeValidation: true`.
9. `parse_mode: Markdown` eats `_` underscores from ElevenLabs agent ids. Use `parse_mode: HTML`.
10. `appendAttribution: false` in any Telegram node's `additionalFields` removes the "sent automatically with n8n" footer without a license.

## Files

```
README.md       this file
README.ru.md    Russian version
STATUS.md       full architecture + test-task mapping
schema.sql      MySQL DDL
workflow.json   n8n export (43 nodes)
.env.example    env template
```

## Status

Production: n8n live on a US VPS. Workflow `ElevenLabs Voice Agent Bot` (id `72ad4b58019c4be3`) is active. The bot at [t.me/northbridge_ai_bot](https://t.me/northbridge_ai_bot) responds.

All three §2 capabilities verified end-to-end on the production ElevenLabs account:

- `update_agent_prompt` → agent's system prompt now reads "ты дружелюбный ассистент"
- `update_agent_welcome` → agent's `first_message` now reads "Да, привет, мир."
- `create_knowledge_doc` + `attach_knowledge_to_agent` → knowledge base entry "Лось" attached
