# ElevenLabs Telegram Bot

Telegram-бот для управления голосовыми агентами ElevenLabs Conversational AI. Каждый пользователь регистрирует свои агенты и редактирует их параметры (системный промпт, приветствие, базу знаний) без захода в дашборд ElevenLabs.

## Стек

- **n8n** (self-hosted, US VPS) — оркестрация. 49 узлов, один webhook-триггер на Telegram
- **MySQL 8** — пользователи, агенты, FSM-сессии, аудит-лог
- **ElevenLabs Conversational AI API** — CRUD агентов, прикрепление knowledge base
- **Cloudflare Tunnel** — HTTPS-доступ к n8n без открытых портов на VPS

## Возможности

| Команда | Что делает |
|---|---|
| `/start` | Регистрирует пользователя в `users`, создаёт пустую сессию, открывает главное меню |
| `/menu` | Показывает главное меню (Мои агенты + Добавить агента) |
| `/add` | Запускает создание нового агента — бот спрашивает имя, сам зовёт `POST /v1/convai/agents/create`, пишет в `user_agents` |
| `/cancel` | Сбрасывает FSM-состояние, возвращает в idle |
| `/help` | Печатает справку |

Из меню агента доступно: редактирование системного промпта, приветственного сообщения, knowledge base (загрузка текста в `/v1/convai/knowledge-base` + прикрепление к агенту), переключение между агентами, удаление.

Все операции с агентом проходят через **проверку владения** — каждый запрос на изменение делает JOIN `user_agents` × `users` по `telegram_user_id`, и если строка не вернулась → action логируется как `denied` и пользователь получает отказ. Сырой `elevenlabs_agent_id` никогда не уходит в `callback_data` Telegram-клавиатуры; используется внутренний `user_agents.id`.

## Архитектурные решения

- **FSM в БД, не в памяти n8n.** `user_sessions.current_action` (`idle` / `awaiting_prompt` / `awaiting_welcome` / `awaiting_kb_text` / `awaiting_agent_name`) — единственный источник истины. n8n может пережить рестарт без потери контекста.
- **`user_agents.id` (INT) в callback_data.** Никогда не отдаём raw ElevenLabs ID в Telegram. Это и приватность, и защита от подделки.
- **`action_logs` без FK на users.** Audit trail переживает удаление пользователя — важно для разбора инцидентов.
- **`/start: Upsert User` использует `INSERT … ON DUPLICATE KEY UPDATE`** по `telegram_user_id` — идемпотентно, можно жать /start сколько угодно.

## Установка

1. Скопировать `.env.example` → `.env`, заполнить
2. `mysql < schema.sql`
3. Импортировать `workflow.json` в n8n (Workflows → Import)
4. Завести в n8n три credential:
   - **MySQL** — `elevenlabs_telegram_bot`
   - **Telegram** — Bot Token из @BotFather
   - **HTTP Header Auth** для ElevenLabs — header `xi-api-key`, value = ваш ElevenLabs API key (нужны scopes `convai_*`)
5. Webhook от Telegram прикрепить на узел `TG Trigger` (n8n покажет URL после активации workflow)
6. Активировать workflow

## Переменные окружения

| Variable | Где используется |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Прямой вызов Bot API из узла `LIST: Send` (httpRequest) — обход бага n8n Telegram-узла, см. ниже |
| `ELEVENLABS_API_KEY` | HTTP Header Auth credential `xi-api-key` |
| `MYSQL_*` | MySQL credential |

На n8n-сервере для доступа к `$env.*` нужен флаг **`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`** (drop-in `/etc/systemd/system/n8n.service.d/env-access.conf`).

## База данных

См. `schema.sql`. Четыре таблицы:

- `users` — UNIQUE по `telegram_user_id`
- `user_agents` — UNIQUE `(user_id, elevenlabs_agent_id)`, soft delete через `is_active`
- `user_sessions` — PK по `telegram_user_id`, ENUM FSM
- `action_logs` — append-only, без FK; индексы по `action_type`, `status`, `created_at`

Каждая операция с агентом начинается с этого JOIN'а (`PROMPT: Get Agent (ownership)`, аналоги для welcome/kb):

```sql
SELECT ua.id, ua.elevenlabs_agent_id, ua.agent_name
FROM user_agents ua
JOIN users u ON u.id = ua.user_id
WHERE u.telegram_user_id = ?
  AND ua.id = ?
  AND ua.is_active = 1;
```

Ноль строк → IF-узел `PROMPT: Agent found?` уводит в `MSG: Cancel Update`, сессия сбрасывается, в логи пишется `denied`.

## Известные подводные камни n8n (что узнали при разработке)

### 1. Динамическая `inline_keyboard` в Telegram-узле молча игнорируется

Узел `n8n-nodes-base.telegram@1.2` при `replyMarkup="inlineKeyboard"` + динамическом `inlineKeyboard.rows = ={{ $json.keyboard.map(...) }}` **выкидывает выражение** и отправляет в Telegram пустой `reply_markup`. Видимо узел смотрит только на fixedCollection-значения, expression на это поле он не вычисляет.

**Лечение:** для динамических клавиатур обходим узел и зовём Bot API напрямую через `httpRequest`:
```
POST https://api.telegram.org/bot{{ $env.TELEGRAM_BOT_TOKEN }}/sendMessage
body: { chat_id, text, reply_markup: { inline_keyboard: [...] } }
```

В этом workflow так сделан узел `LIST: Send` — список агентов после нажатия «🎙 Мои агенты». Статичные клавиатуры (главное меню, меню агента) остались на нативном Telegram-узле — там expression не нужен.

### 2. IF v2 со `strict` typeValidation падает на integer из MySQL

MySQL-узел возвращает `id` как JavaScript number. Если в IF v2 поставить оператор `exists` с `type: "string"` и `conditions.options.typeValidation: "strict"`, узел падает с:
```
NodeOperationError: Wrong type: '5' is a number but was expecting a string [condition 0, item 0]
```
Per-condition `typeValidation: "loose"` это **не** оверрайдит — n8n читает родительский `conditions.options.typeValidation`.

**Лечение:** ставить `parameters.conditions.options.typeValidation: "loose"` + `parameters.looseTypeValidation: true` (оба места, потому что фронт n8n иногда подсовывает одно, бэкенд — другое). Применено к узлу `PROMPT: Agent found?`.

### 3. MySQL-узел и placeholder'ы

В query-параметрах надо использовать формат `={{ $json.foo }}` (с `=`-префиксом) и подключать `executeQuery` режим. Без префикса n8n не интерполирует expression в SQL.

### 4. Webhook URL и Cloudflare Tunnel

Для активации Telegram webhook нужен публичный HTTPS. n8n генерит URL вида `https://<n8n-host>/webhook/<id>`. Cloudflare Tunnel пробрасывает домен → 127.0.0.1:5678. После рестарта n8n webhook-ID не меняется — Telegram-подписку не надо переустанавливать.

## Структура репо

```
.
├── README.md            # этот файл
├── schema.sql           # MySQL DDL
├── workflow.json        # экспорт n8n workflow (49 узлов)
├── .env.example         # шаблон переменных окружения
└── .gitignore
```

## Состояние

Прод: n8n активен на US VPS, workflow `ElevenLabs Voice Agent Bot` (`id: 72ad4b58019c4be3`) — `active=1`. На дату последнего коммита в БД 4 живых агента, прошли успешно: `create_agent` ×4, `edit_prompt`, `edit_welcome`, `edit_kb`.
