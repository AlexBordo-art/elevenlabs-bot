# ElevenLabs Telegram Bot

[English](README.md) | Русский

Telegram-бот для управления голосовыми агентами ElevenLabs Conversational AI. Каждый пользователь регистрирует свои агенты в боте и редактирует их параметры (системный промпт, приветствие, базу знаний), не заходя в дашборд ElevenLabs.

## Стек

- **n8n** (self-hosted, US VPS) — оркестрация. 49 узлов, один webhook-триггер на Telegram
- **MySQL 8** — пользователи, агенты, FSM-сессии, аудит-лог
- **ElevenLabs Conversational AI API** — CRUD агентов, создание knowledge base и прикрепление к агенту
- **Cloudflare Tunnel** — HTTPS-доступ к n8n без открытых портов на VPS

## Что бот умеет

| Команда | Что делает |
|---|---|
| `/start` | Регистрирует пользователя в `users`, создаёт пустую сессию, открывает главное меню |
| `/menu` | Показывает главное меню (Мои агенты + Добавить агента) |
| `/add` | Создаёт нового агента. Бот спрашивает имя, зовёт `POST /v1/convai/agents/create`, пишет строку в `user_agents` |
| `/cancel` | Сбрасывает FSM-состояние, возвращает в idle |
| `/help` | Печатает справку |

Из меню агента доступно: редактирование системного промпта, приветственного сообщения, замена knowledge base (загрузка текста в `/v1/convai/knowledge-base` + attach к агенту), переключение между агентами, удаление.

Все операции с агентом проходят через **проверку владения**: каждый запрос на изменение делает JOIN `user_agents × users` по `telegram_user_id`, и если строка не вернулась, action логируется как `denied`, пользователь получает отказ. Сырой `elevenlabs_agent_id` никогда не уходит в `callback_data` Telegram-клавиатуры — используется внутренний `user_agents.id`.

## Что управляется из бота vs из дашборда ElevenLabs

Бот закрывает то, что формирует **поведение и знания агента**: системный промпт, приветственное сообщение, knowledge base. Это то, что просили в ТЗ.

Всё остальное оставлено на дашборд ElevenLabs: выбор LLM (GPT-4o, Gemini 2.0 Flash, Claude 3.5 Sonnet, custom_llm endpoint), выбор голоса, tools/функции, телефонные номера, конфигурация сессий. Всё это есть в том же ElevenLabs API и при необходимости легко добавляется в бота: например, `agent.prompt.llm` правится тем же `PATCH /v1/convai/agents/{id}`, что уже используется для промпта.

## Архитектурные решения

- **FSM в БД, не в памяти n8n.** `user_sessions.current_action` (`idle` / `awaiting_prompt` / `awaiting_welcome` / `awaiting_kb_text` / `awaiting_agent_name`) — единственный источник истины. n8n может пережить рестарт без потери контекста ни у одного пользователя.
- **`user_agents.id` (INT) в callback_data.** Сырой ElevenLabs ID не уходит в Telegram — это и приватность, и защита от подделки callback.
- **`action_logs` без FK на users.** Audit trail переживает удаление пользователя — важно для разбора инцидентов.
- **`/start: Upsert User` использует `INSERT … ON DUPLICATE KEY UPDATE`** по `telegram_user_id`. Идемпотентно: можно жать /start сколько угодно.

## Установка

1. Скопировать `.env.example` → `.env`, заполнить
2. `mysql < schema.sql`
3. Импортировать `workflow.json` в n8n (Workflows → Import)
4. Завести в n8n три credential:
   - **MySQL** — `elevenlabs_telegram_bot`
   - **Telegram** — Bot Token из @BotFather
   - **HTTP Header Auth** для ElevenLabs — header `xi-api-key`, value — ваш ElevenLabs API key (нужны scopes `convai_*`)
5. Webhook от Telegram прикрепить на узел `TG Trigger` (n8n покажет URL после активации workflow)
6. Активировать workflow

## Переменные окружения

| Variable | Где используется |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Прямой вызов Bot API из узла `LIST: Send` (httpRequest) — обход бага n8n Telegram-узла, см. ниже |
| `ELEVENLABS_API_KEY` | HTTP Header Auth credential `xi-api-key` |
| `MYSQL_*` | MySQL credential |

На n8n-сервере для доступа к `$env.*` в узлах нужен флаг **`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`** (drop-in `/etc/systemd/system/n8n.service.d/env-access.conf`).

## База данных

См. `schema.sql`. Четыре таблицы:

- `users` — UNIQUE по `telegram_user_id`
- `user_agents` — UNIQUE `(user_id, elevenlabs_agent_id)`, soft delete через `is_active`
- `user_sessions` — PK по `telegram_user_id`, ENUM FSM
- `action_logs` — append-only, без FK; индексы по `action_type`, `status`, `created_at`

Каждая операция с агентом начинается с этого JOIN (`PROMPT: Get Agent (ownership)`, аналоги для welcome/kb):

```sql
SELECT ua.id, ua.elevenlabs_agent_id, ua.agent_name
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.id = ?
  AND ua.is_active = 1;
```

Ноль строк — IF-узел `PROMPT: Agent found?` уводит в `MSG: Cancel Update`, сессия сбрасывается, в `action_logs` пишется `denied`.

## Грабли n8n (что узнал по дороге)

### 1. Динамическая `inline_keyboard` молча игнорируется Telegram-узлом

`n8n-nodes-base.telegram@1.2` при `replyMarkup="inlineKeyboard"` плюс динамическом `inlineKeyboard.rows = ={{ $json.keyboard.map(...) }}` **выкидывает выражение** и отправляет в Telegram пустой `reply_markup`. Узел читает только fixedCollection-значения, expression на это поле он не вычисляет.

**Обход:** для динамических клавиатур обходим узел и зовём Bot API напрямую через `httpRequest`:
```
POST https://api.telegram.org/bot{{ $env.TELEGRAM_BOT_TOKEN }}/sendMessage
body: { chat_id, text, reply_markup: { inline_keyboard: [...] } }
```

Так сделан узел `LIST: Send`, который строит клавиатуру для «Мои агенты» после нажатия кнопки меню. Статичные клавиатуры (главное меню, меню агента) остались на нативном Telegram-узле — там expression не нужен.

### 2. IF v2 со strict typeValidation падает на integer из MySQL

MySQL-узел возвращает `id` как JavaScript number. Если в IF v2 поставить оператор `exists`, тип `"string"` и `conditions.options.typeValidation: "strict"`, узел падает с:
```
NodeOperationError: Wrong type: '5' is a number but was expecting a string [condition 0, item 0]
```
Per-condition `typeValidation: "loose"` это **не** оверрайдит — n8n читает родительский `conditions.options.typeValidation`.

**Лечение:** ставить `parameters.conditions.options.typeValidation: "loose"` **и** `parameters.looseTypeValidation: true` (оба места, потому что редактор n8n показывает одно, а runtime читает другое). Применено к узлу `PROMPT: Agent found?`.

### 3. MySQL-узел и placeholder'ы

В query-параметрах надо использовать формат `={{ $json.foo }}` (с `=`-префиксом) и `executeQuery` режим. Без префикса n8n не интерполирует expression в SQL.

### 4. Webhook URL и Cloudflare Tunnel

Для активации Telegram webhook нужен публичный HTTPS. n8n генерит URL вида `https://<n8n-host>/webhook/<id>`. Cloudflare Tunnel пробрасывает домен на `127.0.0.1:5678`. После рестарта n8n webhook-ID не меняется — Telegram-подписку переустанавливать не нужно.

## Структура репо

```
.
├── README.md            # английская версия (основная)
├── README.ru.md         # этот файл
├── schema.sql           # MySQL DDL
├── workflow.json        # экспорт n8n workflow (49 узлов)
├── .env.example         # шаблон переменных окружения
└── .gitignore
```

## Состояние

Прод: n8n активен на US VPS, workflow `ElevenLabs Voice Agent Bot` (`id: 72ad4b58019c4be3`) — `active=1`. На дату последнего коммита в БД живые агенты, прогнаны end-to-end: `create_agent` ×4, `edit_prompt`, `edit_welcome`, `edit_kb` — все success в `action_logs`.
