# ElevenLabs Telegram Bot

[English](README.md) | Русский

Telegram-бот для управления своими голосовыми агентами ElevenLabs. Можно говорить с ним голосом или текстом, обычным языком. Бот сам понимает, у какого агента и что менять, и делает изменение через API ElevenLabs.

Сделан как тестовое задание на позицию Automation Developer в profichat.net.

## Демо

Бот: [t.me/northbridge_ai_bot](https://t.me/northbridge_ai_bot)

`/start`, дальше либо выбрать агента из меню, либо просто написать или сказать голосом, что нужно:

- "update testgolden welcome to Hello world"
- "у Тор поменяй промпт на дружелюбный ассистент"
- "добавь в базу знаний sdfsd: компания основана в 2020 году"

## Стек

- n8n — оркестрация, native AI Agent (LangChain) pattern
- Google Gemini 2.5 Flash — языковая модель для агента и распознавание голоса
- MySQL 8 — пользователи, агенты, сессии, аудит-лог
- ElevenLabs Conversational AI API
- Telegram Bot API
- Cloudflare Tunnel для webhook'а

## Архитектура

В ТЗ UX разделён на два пути:

- §2 "When a user sends messages": модифицировать промпт, приветствие, базу знаний.
- §4 "From the Telegram bot menu": посмотреть агентов, выбрать активного.

Сделал ровно так. Кнопки отвечают за навигацию. Сообщения (текст и голос) идут в AI Agent и делают модификации.

```
Telegram update
  ├─ callback_query  → меню          (LIST, SELECT, ADD)
  └─ message         → AI Agent      (5 tools)
```

### AI Agent

```
Telegram Trigger
  → Parse Update (нормализация, детект голоса)
  → MSG: Route (отделяем /commands)
  → TXT: Get Session → TXT: Route FSM (если в FSM — туда; иначе → AI)
  → AI: Get User Agents (MySQL: агенты этого юзера)
  → AI: Is Voice?
       ├ голос → Get File Meta → Download → Encode → Transcribe (Gemini STT)
       └ текст → проброс
  → Build Agent Context (system prompt со встроенным списком агентов юзера)
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

43 узла.

### Почему native AI Agent

Первая версия разбирала намерения руками: HTTP к Gemini, Code-узел парсит JSON, Switch по action. Работало, но это n8n как контейнер для JavaScript, а не n8n. Переписал на native pattern: AI Agent с sub-node connections (`ai_languageModel`, `ai_memory`, `ai_tool`). У каждого tool явная JSON `inputSchema`, поэтому Gemini генерирует корректные function calls.

## Безопасность (§3)

Два слоя.

Чтения через меню делают JOIN `user_agents × users ON u.id = ua.user_id WHERE telegram_user_id = ?`. Ноль строк — агента не существует для этого юзера. В `callback_data` inline-клавиатуры уходит внутренний `user_agents.id`, не сырой ElevenLabs id, так что подделать callback с чужим id нельзя.

Для AI-пути `Build Agent Context` подтягивает агентов юзера из MySQL до запуска агента и встраивает их в системный промпт. Gemini видит только id юзера. Параметры tools типизированы JSON-схемой, выдумать чужой id модель не может.

Таблица `action_logs` — append-only аудит со статусами `success`, `error`, `denied`.

## База данных

См. `schema.sql`. Четыре таблицы.

| Таблица | Назначение |
|---|---|
| `users` | Telegram-юзеры, UNIQUE по `telegram_user_id` |
| `user_agents` | Связь юзер ↔ ElevenLabs-агент. UNIQUE `(user_id, elevenlabs_agent_id)`. Soft-delete через `is_active` |
| `user_sessions` | FSM для `/add`-флоу (спрашиваем имя нового агента). Остальное stateless |
| `action_logs` | Append-only аудит |

Ownership-запрос на каждом чтении меню:

```sql
SELECT ua.id, ua.agent_name, ua.elevenlabs_agent_id
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.is_active = 1
ORDER BY ua.created_at DESC;
```

## Tools (5 возможностей для Gemini)

У каждого `toolCode` явная `inputSchema` и JavaScript, дёргающий ElevenLabs.

| Tool | Method | Endpoint | Inputs |
|---|---|---|---|
| `get_agent_config` | GET | `/v1/convai/agents/{agentId}` | `agentId` |
| `update_agent_prompt` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `newPrompt` |
| `update_agent_welcome` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `newFirstMessage` |
| `create_knowledge_doc` | POST | `/v1/convai/knowledge-base/text` | `docName`, `docText` |
| `attach_knowledge_to_agent` | PATCH | `/v1/convai/agents/{agentId}` | `agentId`, `docId`, `docName` |

Для базы знаний агент сначала зовёт `create_knowledge_doc` чтобы получить id документа, потом `attach_knowledge_to_agent`. Зависимость между двумя вызовами Gemini обрабатывает сам.

## Установка

1. Скопировать `.env.example` в `.env`, заполнить.
2. `mysql < schema.sql`.
3. Импортировать `workflow.json` в n8n.
4. Завести четыре credential:
   - MySQL → `elevenlabs_telegram_bot`
   - Telegram → bot token от @BotFather
   - HTTP Header Auth для ElevenLabs → header `xi-api-key`, value = ключ ElevenLabs со scopes `convai_*`
   - Google Palm API для Gemini Chat Model, ключ из Google AI Studio
5. Привязать webhook от Telegram к узлу `TG Trigger` (URL n8n покажет после активации).
6. Активировать workflow.

## Переменные окружения

На хосте (мы прокинули через systemd drop-in):

| Variable | Где используется |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` | разрешает `$env.*` в Code / HTTP-узлах |
| `N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true` | разрешает использование langchain-tools |
| `TELEGRAM_BOT_TOKEN` | `LIST: Send` (прямой Bot API для динамической клавиатуры) |
| `ELEVENLABS_API_KEY` | 5 Code Tools |
| `GOOGLE_API_KEY` | `AI: Transcribe` (HTTP-вызов Gemini STT) |

## Грабли n8n, на которые наступил

Что неочевидно, если будешь переиспользовать части этого workflow.

1. `toolHttpRequest` v1.1 в n8n 2.19.5 не работает с langchain Agent: runtime пытается вызвать `.execute()`, у узла только `.supplyData()`. Обход: `toolCode` v1.3 с явным `inputSchema` и `this.helpers.httpRequest` внутри.
2. `$helpers` недоступен в task-runner sandbox. Внутри Code-узла binary читать через `this.helpers.getBinaryDataBuffer(0, 'data')`. `N8N_RUNNERS_ENABLED=false` в 2.19.5 runner не отключает.
3. `require('mysql2/promise')` заблокирован даже с `NODE_FUNCTION_ALLOW_EXTERNAL=mysql2`. Sandbox langchain-tool этот флаг не учитывает. Если нужен MySQL внутри tool — выводи через webhook sub-workflow.
4. `$fromAI()` в `toolHttpRequest` в этой версии не генерирует function declarations корректно для Gemini (пустые ключи в `parameters.properties` → 400 от Gemini). Либо литеральные `{placeholder}` + `placeholderDefinitions`, либо `toolCode` с `inputSchema`.
5. Switch роутит по case index, а не по `outputKey`. Перепишешь правила — связи нужно удалить и добавить заново с правильным `sourceIndex`. Auto-sanitization это не чинит.
6. `leftValue` в Switch context-aware. Если input идёт от узла B, а ты хочешь роутить по полю узла A — пиши `$('A').item.json.field`. `$json` смотрит на то, что кормит Switch.
7. Динамическая `inline_keyboard` в `n8n-nodes-base.telegram@1.2` молча игнорирует expression на `inlineKeyboard.rows`. Для списка агентов этот workflow обходит узел и зовёт Bot API напрямую через `$env.TELEGRAM_BOT_TOKEN`.
8. IF v2 со строгим `typeValidation` падает на integer-id из MySQL (это JS number). Фикс: `parameters.conditions.options.typeValidation: "loose"` и `parameters.looseTypeValidation: true`.
9. `parse_mode: Markdown` съедает `_` underscore из id-шников ElevenLabs. Используй `parse_mode: HTML`.
10. `appendAttribution: false` в `additionalFields` любого Telegram-узла убирает плашку "sent automatically with n8n" без активации лицензии.

## Файлы

```
README.md       английская версия
README.ru.md    этот файл
STATUS.md       полная архитектура + соответствие ТЗ
schema.sql      MySQL DDL
workflow.json   экспорт workflow n8n (43 узла)
.env.example    шаблон env-переменных
```

## Статус

Прод: n8n живой на US VPS. Workflow `ElevenLabs Voice Agent Bot` (id `72ad4b58019c4be3`) активен. Бот на [t.me/northbridge_ai_bot](https://t.me/northbridge_ai_bot) отвечает.

Все три возможности §2 проверены end-to-end на проде ElevenLabs:

- `update_agent_prompt` → системный промпт агента теперь "ты дружелюбный ассистент"
- `update_agent_welcome` → `first_message` агента теперь "Да, привет, мир."
- `create_knowledge_doc` + `attach_knowledge_to_agent` → к базе знаний привязан документ "Лось"
