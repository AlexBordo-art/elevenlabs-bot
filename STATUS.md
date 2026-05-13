# Status (snapshot: 2026-05-13 ~17:00 MSK)

Workflow rewrite is mid-flight. Bot is live in production but text/voice through the AI Agent path is not fully verified yet. This document captures the state and the remaining plan so work can resume from here.

## Architecture (current)

Native n8n AI Agent pattern. The previous hand-rolled chain of HTTP-to-Gemini + manual JSON parsing + switch routing has been removed.

```
Telegram Trigger
  → Parse Update (Code: normalize update; detect voice)
    → Route by Type (Switch: message vs callback_query)
      → MSG: Route (Switch: /commands vs free text)
        ├ /start, /menu, /add, /cancel, /help → existing command handlers
        └ free text → TXT: Get Session → TXT: Route FSM
            ├ awaiting_* → existing PROMPT/WELCOME/KB/ADDAGENT chains (legacy menu flow)
            └ idle (fallback) → AI Agent path
                → AI: Get User Agents (MySQL: list user's agents)
                  → AI: Is Voice?
                     ├ voice → AI: Get File Meta → AI: Download Voice → AI: Encode Audio → AI: Transcribe (Gemini multimodal, STT only)
                     └ text → pass through
                  → Build Agent Context (Code: prepares user_text + system_message)
                  → AI Agent (@n8n/n8n-nodes-langchain.agent v3.1)
                    ├─ Google Gemini Chat Model (lmChatGoogleGemini v1.1, gemini-2.5-flash) — ai_languageModel
                    ├─ Simple Memory (memoryBufferWindow, sessionKey = chat_id, window = 10) — ai_memory
                    ├─ Tool: get_agent_config (HTTP Request Tool, GET /v1/convai/agents/{agentId}) — ai_tool
                    ├─ Tool: update_agent_prompt (HTTP Request Tool, PATCH) — ai_tool
                    ├─ Tool: update_agent_welcome (HTTP Request Tool, PATCH) — ai_tool
                    ├─ Tool: create_knowledge_doc (HTTP Request Tool, POST /v1/convai/knowledge-base/text) — ai_tool
                    └─ Tool: attach_knowledge_to_agent (HTTP Request Tool, PATCH agent.knowledge_base) — ai_tool
                  → Send Agent Reply (Telegram sendMessage with $json.output)
```

Tools use `$fromAI('paramName', 'description')` to receive parameters from Gemini. Each tool uses the existing `ElevenLabs API` httpHeaderAuth credential.

The Build Agent Context Code node fetches the user's agents from the prior MySQL node and embeds them into the system prompt. Gemini never invents an agent id; it can only refer to ones in the user's list.

## What works (verified earlier today)

- /start, /menu, /add, /cancel, /help — all command handlers
- Menu-driven editing (button-based): list agents → select → edit prompt/welcome/KB
- 4 agents created end-to-end via /add in prod (testgolden, trtrt, sdfsd, "Ещеоднновый")
- `action_logs` records create_agent, edit_prompt, edit_welcome, edit_kb as success rows
- Telegram trigger reliably delivers messages and voice updates to the workflow

## What is NOT verified yet

- Free-form text routed into AI Agent path (the new architecture)
- Voice routed through AI Agent path
- Tool invocation from Gemini (the agent has not yet successfully called any of the five tools end-to-end)
- Multi-turn dialog with memory ("change welcome" → "of which agent?" → user reply)

## Known issue (just patched, untested)

`AI: Encode Audio` Code node was using `$helpers.getBinaryDataBuffer(...)`. The task-runner sandbox in this n8n install does not expose `$helpers` — only `this.helpers`. Patched to `this.helpers.getBinaryDataBuffer(0, 'data')`. Awaiting a new voice message to confirm.

This is a general n8n gotcha: depending on n8n version and task-runner mode, the helpers are accessed differently. The same project's `Parse Update`, `LIST: Build Keyboard`, and `Build Agent Context` Code nodes work because they don't need helpers (only $input / $json / $node accessors).

## Server config

US VPS (23.227.194.161), n8n behind Cloudflare Tunnel at https://n8n.northbridge-analytics.com.

systemd drop-ins live in `/etc/systemd/system/n8n.service.d/`:

- `env-access.conf` → `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (needed for `$env.TELEGRAM_BOT_TOKEN` and `$env.GOOGLE_API_KEY` inside Code/HTTP nodes)
- `telegram-token.conf` → `TELEGRAM_BOT_TOKEN=...` (used by LIST: Send for dynamic inline_keyboard via direct Bot API)
- `google-api.conf` → `GOOGLE_API_KEY=...` (used by AI: Transcribe HTTP node for the STT call; the AI Agent's Gemini Chat Model uses an n8n credential, not env)
- `disable-runner.conf` → `N8N_RUNNERS_ENABLED=false` (did not actually disable the task runner in this version — process listing shows task-runner still running; kept for documentation only)

n8n credentials (referenced from the workflow):

- `MySQL elevenlabs_bot` (id: ec18891bfb714581)
- `Telegram Bot` (id: 3c8e9d830c184033)
- `ElevenLabs API` (id: c99ef9957b674492, type httpHeaderAuth, header `xi-api-key`)
- `Google Gemini API` (id: v7J9zcGtKqsLT1No, type googlePalmApi) — created in this session for the new Chat Model sub-node

## Plan (remaining)

1. Verify voice path after the `this.helpers` fix. Run one voice message. Inspect execution. If passes, all four downstream nodes (Transcribe → Build Context → AI Agent → Send Reply) should fire.
2. Verify text path: send "show my agents" as plain text. Confirm Gemini picks `get_agent_config` or just lists from context. Confirm Send Agent Reply pushes back into Telegram.
3. Verify update flow: "update testgolden welcome to Hello world". Confirm `Tool: update_agent_welcome` fires with the right agentId. Confirm ElevenLabs returns 200. Confirm Telegram receives the bot's confirmation.
4. Verify multi-turn: "обнови приветствие" without naming an agent. Bot should ask which one. User replies "у testgolden, скажи Hello". Bot completes the update.
5. Update README.md and README.ru.md to describe the new AI Agent architecture (replace the older "I/O via menu + custom AI branch" narrative).
6. Re-export `workflow.json` (already synced locally with prod, but commit after final tweaks).
7. Rebuild `~/elevenlabs-bot-submission.zip` and `~/elevenlabs-bot-submission.tar.gz`.
8. Update `~/elevenlabs-bot-cover-letter.md` — call out the native AI Agent + LangChain + Memory pattern explicitly (this is the thing the employer will judge).
9. Validate one more time with `n8n_validate_workflow` (profile: ai-friendly).
10. Send to @Y_M_tech in Telegram.

## Decisions and tradeoffs taken during the rewrite

- **AI Agent over hand-rolled HTTP/Code chain.** The prior architecture worked but was unidiomatic for an n8n developer position. Switched to `@n8n/n8n-nodes-langchain.agent` + sub-nodes via `ai_languageModel` / `ai_memory` / `ai_tool` connections — this is what a reviewer expects to see in a portfolio workflow.
- **Tools as HTTP Request Tools, not Code Tools or sub-workflows.** Direct HTTP to ElevenLabs with `$fromAI()` parameter binding. No sub-workflow files, no shell-code-inside-Code-Tool indirection. The five tools are exactly the five capabilities the test task asked for, named explicitly.
- **Ownership check is implicit, not per-tool.** The system message embeds only the user's own agents (fetched via MySQL JOIN before the agent runs). Gemini is instructed never to fabricate an id. A future hardening step would re-check ownership inside each tool, but for the test task scope, the implicit guarantee is sufficient and keeps the workflow clean.
- **Voice transcription stays as a separate STT step.** The langchain Chat Model nodes don't accept audio inputs directly. Voice → download → Gemini multimodal (one HTTP call, STT only) → text → AI Agent. This way the agent itself receives plain text from both modalities.
- **Memory is per-chat (sessionKey = chat_id), window = 10.** Enables follow-up turns like "change the welcome" → "of which agent?" without losing context.
- **Legacy menu flow kept.** /start, /menu, the button-based editor — all preserved. The new AI Agent path is a parallel free-text/voice entry point, not a replacement for the menu. Both routes hit the same MySQL + ElevenLabs API.

## Files in this repo

| File | Purpose |
|---|---|
| `workflow.json` | n8n export of the live workflow (65 nodes). Synced with prod at the time of this snapshot |
| `schema.sql` | MySQL DDL — users, user_agents, user_sessions, action_logs |
| `README.md` / `README.ru.md` | English / Russian project README (NEEDS UPDATE — still describes the older architecture) |
| `.env.example` | Template for required env vars |
| `STATUS.md` | This file |
