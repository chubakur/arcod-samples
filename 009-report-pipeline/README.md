# 009 — Report Pipeline

Конвейер текстовых отчётов: загрузка в объектное хранилище, постановка задания
в очередь, обработка воркером и запись результата в реляционную БД. Четыре
интеграции в одном сервисе — не «сервис + kv».

## Стек

| Компонент | Роль | Provider |
|-----------|------|----------|
| `ReportPipeline` | HTTP API + consumer очереди | — |
| `db` | отчёты и outbox | `mysql` |
| `s3` | тело отчёта | `s3` (MinIO) |
| `mq` | очередь заданий | `rabbitmq` |

```
POST /v1/reports ──▶ mysql: status=queued
                 └─▶ s3: body
                 └─▶ outbox ──▶ rabbitmq jobs ──▶ consumer:
                                                    s3.read → count → mysql: done
```

Публикация идёт через outbox в той же транзакции, что и запись отчёта, поэтому
задание не теряется между коммитом и брокером.

## API

- `POST /v1/reports` — `{name, body}`; сохраняет тело, ставит в очередь, отдаёт запись.
- `GET /v1/reports/:id` — статус и статистика (`queued`, `done`, `failed`).
- `POST /v1/reports/:id/retry` — вернуть в очередь; на `queued` — `409 Conflict`.

## Запуск

```bash
arcod check
arcod build --impl --port 8094
docker compose -f .arcod/build/docker-compose.yml up -d
./smoke.sh          # полный прогон, PASS в конце
```

Остановка: `docker compose -f .arcod/build/docker-compose.yml down -v`.
`arcod run --down` не используем — issue #2.

## Опыт использования Arc

Что нашлось на этом проекте:

- `io.find` в сгенерированном SQLStore падает: локальная переменная `const q = query`
  перекрывает функцию квотирования `q(name)` → любой список отдаёт 500. Список
  пришлось убрать из контракта, поэтому эндпоинта `GET /v1/reports` нет (issue #22).
- Песочница `impl` считает `io.fetch(...)` сырым сетевым вызовом из-за regex
  `\bfetch\s*\(`; пришлось писать `io['fetch'](...)` (issue #23).
- `bind store -> postgres(...)` создаёт Postgres, но сгенерированный store говорит
  по MySQL-протоколу и `/healthz` зависает навсегда; рабочий вариант — mysql (issue #24).
