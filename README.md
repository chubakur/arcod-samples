# arcod-samples

Песочница для языка [Arcod](https://github.com/chubakur/arcod): каждый каталог —
отдельный небольшой backend-проект, описанный одним `.arc`-файлом и реализацией
операций в `impl/*.mjs`.

Цель — проверять язык на разнообразных задачах, а не собирать коллекцию
одинаковых CRUD. Найденные ограничения и баги уходят в issue
[`chubakur/arcod`](https://github.com/chubakur/arcod/issues).

## Проекты

| # | Проект | Идея | Возможности Arc |
|---|--------|------|-----------------|
| 001 | [expense-splitter](001-expense-splitter/) | Совместные траты и балансы | `kv`, `ids`, типы-записи, ошибки, валидация |
| 002 | [webhook-inbox](002-webhook-inbox/) | Вебхуки: идемпотентность, очередь, повторы, DLQ | `kv`, `queue`, `jobs`, `ids`, retry, дедупликация |

Очередь идей и ротация возможностей — [IDEAS.md](IDEAS.md).

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
