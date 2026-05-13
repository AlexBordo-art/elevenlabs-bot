# Status (snapshot: 2026-05-13 ~18:25 MSK)

Working end-to-end. Architecture cleaned: 65 → 43 nodes. Menu = view+select only (per Test Task section 4). Messages = modify (per Test Task section 2). One path per task, no duplicate logic.

## Architecture

```
Telegram Trigger
  → Parse Update (Code: normalize, detect voice)
    → Route by Type (Switch: message vs callback)
       ├ callback_query → CB: Answer → CB: Route Action
       │     ├ "list_agents"  → LIST: Get Agents → LIST: Build Keyboard → LIST: Send (direct Bot API for dynamic inline keyboard)
       │     ├ "select"       → SELECT: Set Selected → SELECT: Get Agent → SELECT: Send Agent Menu (active-agent card, no edit buttons)
       │     ├ "add_agent"    → ADD: Set State → ADD: Ask
       │     └ "menu"         → Send Main Menu
       │
       └ message → MSG: Route
             ├ /start  → /start: Upsert User → /start: Init Session → Send Main Menu
             ├ /menu   → Send Main Menu
             ├ /help   → MSG: Help
             ├ /add    → ADD: Set State → ADD: Ask
             └ text/voice (fallback) → TXT: Get Session → TXT: Route FSM
                   ├ awaiting_agent_name → ADDAGENT: Create at ElevenLabs → Created OK? → Insert/LogError → Confirm/Reply
                   └ idle (fallback) → AI: Get User Agents
                         → AI: Is Voice?
                            ├ voice → AI: Get File Meta → AI: Download Voice → AI: Encode Audio → AI: Transcribe (Gemini multimodal STT)
                            └ text → pass through
                         → Build Agent Context (Code: builds system_message with embedded agent list)
                         → AI Agent (@n8n/n8n-nodes-langchain.agent v3.1)
                            ├─ Google Gemini Chat Model 2.5 Flash (ai_languageModel)
                            ├─ Simple Memory (sessionKey = chat_id, window = 10) (ai_memory)
                            └─ 5 Code Tools (toolCode v1.3, ai_tool):
                                Tool: get_agent_config
                                Tool: update_agent_prompt
                                Tool: update_agent_welcome
                                Tool: create_knowledge_doc
                                Tool: attach_knowledge_to_agent
                         → Send Agent Reply (Telegram, HTML parse_mode, appendAttribution=false)
```

43 nodes, 40 connections.

## Mapping to Test Task requirements

| Test Task requirement | Implementation |
|---|---|
| §2 Modify prompt via message | Free text/voice → AI Agent → Tool: update_agent_prompt |
| §2 Update welcome via message | Free text/voice → AI Agent → Tool: update_agent_welcome |
| §2 Update knowledge base via message | Free text/voice → AI Agent → Tool: create_knowledge_doc + attach_knowledge_to_agent |
| §3 Security: only own agents | `user_agents × users` ownership JOIN on every menu read. AI Agent's system message embeds only the user's own agents (fetched via MySQL JOIN before agent runs); the model cannot reference IDs it doesn't see. |
| §4 View agents from menu | Inline button "🎙 Мои агенты" → LIST: chain |
| §4 Select agent from menu | Tap on agent button → SELECT: chain → active-agent set, card displayed |
| Tech: n8n | Yes, native AI Agent + LangChain sub-nodes + Code/HTTP/MySQL/Telegram nodes |
| Tech: MySQL | Yes, 4 tables (users, user_agents, user_sessions, action_logs) with FKs and audit log |
| Tech: REST integrations | ElevenLabs + Telegram Bot API + Google Generative Language API |
| Tech: Clean structure | Single path per task: menu for navigation, messages for action |

## n8n gotchas hit during this build

1. **`toolHttpRequest` v1.1 has supplyData/execute mismatch** in this n8n version. Workaround: use `toolCode` v1.3 with `inputSchema` (JSON Schema), call `this.helpers.httpRequest` directly. Pass API keys via `$env.*`, the sandbox can't reach credentials.

2. **`$helpers` is not in the task-runner sandbox**. Use `this.helpers.getBinaryDataBuffer(0, 'data')` in Code nodes.

3. **`require('mysql2/promise')` is blocked** even with `NODE_FUNCTION_ALLOW_EXTERNAL=mysql2`. The langchain Code Tool sub-sandbox doesn't honor that flag. If you need MySQL inside a tool, expose it via a separate webhook sub-workflow.

4. **`$fromAI()` placeholder pattern** in HTTP Request Tool doesn't generate Gemini function declarations correctly in this version. Use literal `{placeholder}` with `placeholderDefinitions` — or just use Code Tools with explicit `inputSchema`.

5. **`parse_mode: Markdown`** in Telegram node eats `_` underscores from ElevenLabs agent IDs. Use `parse_mode: HTML`.

6. **`appendAttribution: false`** in Telegram node `additionalFields` removes the n8n footer. No license activation needed.

7. **Dynamic `inline_keyboard` in Telegram node v1.2** silently ignores expressions on `inlineKeyboard.rows`. For LIST: Send the workaround is direct Bot API HTTP call with `$env.TELEGRAM_BOT_TOKEN`.

8. **IF v2 with strict `typeValidation` rejects MySQL integer ids**. Set `parameters.conditions.options.typeValidation: "loose"` AND `parameters.looseTypeValidation: true`.

9. **Switch node `leftValue` matters: context-aware**. If the Switch's input comes from node B (e.g. `CB: Answer` returns Telegram API ack), and you want to route on a field from upstream node A (`Parse Update`), use `$('Parse Update').item.json.field`, not `$json.field`. Otherwise rules read B's output and never match.

10. **Switch `outputKey` is a label only**, real routing is by case index. When changing rule order or removing rules, all existing connections must be removed and re-added with matching sourceIndex. Auto-sanitization doesn't fix this.

## Server config (systemd drop-ins, `/etc/systemd/system/n8n.service.d/`)

- `env-access.conf` — `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`
- `google-api.conf` — `GOOGLE_API_KEY=<key>`
- `elevenlabs-key.conf` — `ELEVENLABS_API_KEY=<key>` (used by Code Tools)
- `telegram-token.conf` — `TELEGRAM_BOT_TOKEN=<token>` (used by LIST: Send direct Bot API call)
- `allow-tool-usage.conf` — `N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true`
- `code-modules.conf` — `NODE_FUNCTION_ALLOW_EXTERNAL=mysql2` (set as a precaution; in this version the langchain Code Tool sandbox does not honor it)

## n8n credentials

- `MySQL elevenlabs_bot` (id: ec18891bfb714581)
- `Telegram Bot` (id: 3c8e9d830c184033)
- `ElevenLabs API` (id: c99ef9957b674492) — httpHeaderAuth, header `xi-api-key`
- `Google Gemini API` (id: v7J9zcGtKqsLT1No) — googlePalmApi, used by langchain Gemini Chat Model

## Remaining work before submission

1. Update README.md / README.ru.md to describe the cleaned native AI Agent architecture (current versions still describe the old 65-node bot)
2. Rebuild `~/elevenlabs-bot-submission.zip` and `~/elevenlabs-bot-submission.tar.gz`
3. Update `~/elevenlabs-bot-cover-letter.md`: lead with the native AI Agent + Tools + Memory pattern, mention voice support
4. Final sanity test: knowledge-base update flow (create_knowledge_doc + attach), multi-turn dialog
5. Send to @Y_M_tech in Telegram

## Submission contact (from Test Task)

Via Telegram: `@Y_M_tech`. WhatsApp: `https://wa.link/xp5e8p`.
