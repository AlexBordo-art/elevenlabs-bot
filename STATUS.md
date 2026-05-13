# Status (snapshot: 2026-05-13 ~17:45 MSK)

End-to-end working. AI Agent successfully invokes tools to update ElevenLabs voice agents from natural-language text and voice input.

## Verified scenarios

- Voice → "у Тор поменяй приветствие" → bot asks "какое новое приветствие?" → user replies → `Tool: update_agent_welcome` fires → ElevenLabs PATCH 200 → confirmation back to user (exec 158)
- Memory works across turns within a chat (sessionKey = chat_id)
- Menu-driven flow (/start, /menu, /add, edit prompt/welcome/KB via buttons) still works in parallel

## Architecture

```
Telegram Trigger
  → Parse Update (Code: normalize, detect voice)
    → Route by Type (Switch: message vs callback)
      → MSG: Route (Switch: /commands vs free text)
        ├ /start, /menu, /add, /cancel, /help → existing handlers
        └ free text/voice → TXT: Get Session → TXT: Route FSM
            ├ awaiting_* → legacy menu update chains
            └ idle fallback → AI: Get User Agents (MySQL)
                → AI: Is Voice?
                   ├ voice → Get File Meta → Download → Encode (this.helpers.getBinaryDataBuffer → base64) → Transcribe (Gemini STT, multimodal HTTP)
                   └ text → pass through
                → Build Agent Context (Code: builds system_message with embedded agent list)
                → AI Agent (@n8n/n8n-nodes-langchain.agent v3.1)
                   ├─ Google Gemini Chat Model (lmChatGoogleGemini v1.1, gemini-2.5-flash) — ai_languageModel
                   ├─ Simple Memory (memoryBufferWindow v1.3, sessionKey = chat_id, window = 10) — ai_memory
                   └─ 5 Code Tools (toolCode v1.3, ai_tool):
                       Tool: get_agent_config
                       Tool: update_agent_prompt
                       Tool: update_agent_welcome
                       Tool: create_knowledge_doc
                       Tool: attach_knowledge_to_agent
                → Send Agent Reply (Telegram, parse_mode=HTML, appendAttribution=false)
```

Total 65 nodes.

## Notable n8n gotchas hit during this rewrite

1. **`toolHttpRequest` v1.1 fails with "supplyData but no execute"** in this n8n version (2.19.5). Workaround: use `toolCode` v1.3 with `inputSchema` (JSON Schema) and call `this.helpers.httpRequest` from inside the JS code. Pass the API key via env var, not credential — code-tool sandbox can't reach credentials.

2. **`$helpers` is undefined in the task-runner sandbox**, must use `this.helpers.getBinaryDataBuffer(0, 'data')` in Code nodes. `N8N_RUNNERS_ENABLED=false` does NOT disable the task runner in this version.

3. **`$fromAI()` placeholder pattern** doesn't generate Gemini function declarations correctly in this version. Use literal `{placeholder}` syntax in URL/body + `placeholderDefinitions` (or move to `toolCode` with `inputSchema` — what we did).

4. **`parse_mode: Markdown`** in Telegram-узле съедает `_` underscores from ElevenLabs agent IDs. Use `parse_mode: HTML` instead, it ignores `_` and `*`.

5. **`appendAttribution: false`** on the Telegram-узел removes the "sent automatically with n8n" footer on community edition. No license activation needed.

6. **Dynamic `inline_keyboard` in Telegram node v1.2** silently ignores expressions on `inlineKeyboard.rows`. Workaround for the LIST: Send node: direct Bot API HTTP call with `$env.TELEGRAM_BOT_TOKEN`.

7. **IF v2 with strict `typeValidation` rejects integer columns from MySQL** (the `id` from a `SELECT` is a JS number, not string). Fix: set both `parameters.conditions.options.typeValidation: "loose"` and `parameters.looseTypeValidation: true`.

## Server config (systemd drop-ins, `/etc/systemd/system/n8n.service.d/`)

- `env-access.conf` — `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`
- `google-api.conf` — `GOOGLE_API_KEY=<key>` (used by AI: Transcribe HTTP call)
- `elevenlabs-key.conf` — `ELEVENLABS_API_KEY=<key>` (used by Code Tools via `$env.*`)
- `telegram-token.conf` — `TELEGRAM_BOT_TOKEN=<token>` (used by LIST: Send for dynamic inline keyboard)
- `allow-tool-usage.conf` — `N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true`
- `disable-runner.conf` — `N8N_RUNNERS_ENABLED=false` (kept for documentation; doesn't actually disable runner in 2.19.5)

## n8n credentials

- `MySQL elevenlabs_bot` (id: ec18891bfb714581) — MySQL on 127.0.0.1
- `Telegram Bot` (id: 3c8e9d830c184033) — bot token
- `ElevenLabs API` (id: c99ef9957b674492) — httpHeaderAuth, header `xi-api-key`
- `Google Gemini API` (id: v7J9zcGtKqsLT1No) — googlePalmApi, used by langchain Gemini Chat Model node

## Remaining work

- Update README.md and README.ru.md to describe the native AI Agent architecture
- Rebuild `~/elevenlabs-bot-submission.zip` and `~/elevenlabs-bot-submission.tar.gz` from current workflow.json
- Update `~/elevenlabs-bot-cover-letter.md` to mention native AI Agent + LangChain + Memory + Tools as the n8n competency demonstration
- Final test: multi-turn dialog, knowledge base update (create_doc + attach), ambiguous agent name handling
- Submit to @Y_M_tech in Telegram
