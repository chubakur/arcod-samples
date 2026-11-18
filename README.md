# arcod-samples

Песочница для языка [Arcod](https://github.com/chubakur/arcod): каждый каталог —
отдельный небольшой backend-проект, описанный одним `.arc`-файлом и реализацией
операций в `impl/*.mjs`.

Цель — проверять язык на разнообразных и смелых задачах, а не собирать
коллекцию одинаковых CRUD. Список идей не ограничен текущими возможностями
Arcod: если чего-то не хватает — это фиксируется в issue, а не отменяет идею. Найденные ограничения и баги уходят в issue
[`chubakur/arcod`](https://github.com/chubakur/arcod/issues).

## Проекты

| # | Проект | Идея | Возможности Arc |
|---|--------|------|-----------------|
| 001 | [expense-splitter](001-expense-splitter/) | Совместные траты и балансы | `kv`, `ids`, типы-записи, ошибки, валидация |
| 002 | [webhook-inbox](002-webhook-inbox/) | Вебхуки: идемпотентность, очередь, повторы, DLQ | `kv`, `queue`, `jobs`, `ids`, retry, дедупликация |
| 003 | [collab-board](003-collab-board/) | Совместная доска: слияние правок без потерь | `kv`, `stream` (websocket), `ids`, идемпотентность |
| 004 | [turn-clock](004-turn-clock/) | Пошаговые партии: банк времени, таймауты, переподключение | `kv`, `stream`, `ids`, `datetime`, проекция журнала |
| 005 | [fence-locks](005-fence-locks/) | Распределённые аренды: fencing token, продление, guard от зависшего держателя | `kv`, `ids`, `unique` как атомарный claim, составные списки в examples |

Очередь идей — [IDEAS.md](IDEAS.md). Журнал фидбека и перепроверка закрытых issue — [ISSUES.md](ISSUES.md).

## Структура каталога

```
NNN-slug/
  README.md   — описание, API, запуск, впечатления от Arc
  main.arc    — модель сервиса
  impl/*.mjs  — тела операций (песочница io)
  smoke.sh    — сборка, запуск, проверки по HTTP
```

## Требования

- Node.js >= 22.18
- Docker
- `arcod` из `chubakur/arcod` (`npm link` в корне того репозитория)

## Общие команды

```bash
cd NNN-slug
arcod check                 # модель и предупреждения
arcod build --impl          # генерация .arcod/build
arcod run --impl --port ... # docker compose
./smoke.sh                  # e2e-проверка проекта
```

Ветка и коммиты: `main`, тема коммита — `NNN: ...`.
