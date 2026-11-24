# 038 — Почтовый шлюз в API

Входящая почта превращается в типизированные события: письмо приходит к
почтовому провайдеру, фоновый консьюмер забирает его по курсору, кладёт тело и
вложения в объектное хранилище, пишет строки в Postgres и ставит в очередь
вторую доставку — подписчику уходит подписанный вебхук. Ответ на `poll` не
ждёт ни одного письма: он только ставит задание.

Это не «сервис + kv». В работе участвуют **пять внешних систем** (Postgres,
Redis-очередь, MinIO/S3, почтовый провайдер за HTTP и подписчик за HTTP) и
**два фоновых консьюмера**. Всё состояние — строки: повторная доставка задания
не создаёт дублей, потому что `(mailboxId, externalId)` — ключ идемпотентности.

## Компоненты

```
   почтовый провайдер            ┌──────────────────────────┐
   (mock inbox :9097)  ◀──pull── │ job ingest               │
        ▲                        │  cursor, dedupe, S3, rows│
        │ POST /messages         └───────┬──────────────────┘
        │ (только для теста)             │ insert Delivery
   ┌────┴─────┐                          ▼
   │  Bridge  │   POST /v1/...   ┌──────────────┐   publish   ┌─────────┐
   │  :8098   │ ◀─────────────── │  Postgres    │ ──────────▶ │  Redis  │
   └────┬─────┘                  │  mailboxes   │             │ очередь │
        │                        │  messages    │             └────┬────┘
        │ GET /v1/messages/:id   │  attachments │                  │ job deliver
        ▼                        │  deliveries  │                  ▼
   ┌──────────┐   blobGet        └──────────────┘        ┌──────────────────┐
   │  MinIO   │ ◀────────────────────────────────────── │ job deliver      │
   │  :9000   │        blobPut (тело, вложения)          │ HMAC + POST      │
   └──────────┘                                          └────────┬─────────┘
                                                                  │ signed JSON
                                                                  ▼
                                                         подписчик (mock sink :9098)
```

## Компонент → provider

| Компонент | Возможность | Провайдер | Внешняя система |
|-----------|-------------|-----------|-----------------|
| `store` | `sql` | `postgres` | Postgres 16 |
| `events` | `queue` | `redis` | Redis 7 (publish/consume/retry/dead) |
| `files` | `blob` | `s3` | MinIO |
| `Inbox` | внешний сервис | `endpoint` | почтовый провайдер (mock `mock/inbox.mjs`) |
| `Sink` | внешний сервис | `endpoint` | подписчик (mock `mock/sink.mjs`) |
| `uuid` | `ids` | `local` | — |

В `docker-compose` поднимаются Postgres, Redis и MinIO. Два HTTP-сервиса —
«чужая» инфраструктура: в примере это моки, в бою — Postmark/SendGrid inbound
(или IMAP-поллер) и endpoint клиента.

## API

| Метод | Путь | Что делает |
|-------|------|------------|
| POST | `/v1/mailboxes` | завести ящик; секрет подписи возвращается один раз (400/409) |
| GET | `/v1/mailboxes/:id` | ящик, курсор, число маршрутов и писем |
| POST | `/v1/routes` | правило: подстрока from/subject → topic (400/404/409) |
| POST | `/v1/mailboxes/:id/poll` | cron-хук: одно задание `ingest` в очередь (404/409) |
| GET | `/v1/messages` | последние 50 писем + total |
| GET | `/v1/messages/:id` | письмо, тело из S3, вложения |
| POST | `/v1/messages/:id/replay` | повторить доставку после `failed` (404/409) |
| GET | `/v1/stats` | счётчики писем, доставок, вложений, dead letter |
| GET | `/v1/dead` | содержимое dead letter темы `deliver` |

Два консьюмера:

- `ingest` (`retry: 3`) — `Inbox.pull` по курсору, дедуп по `externalId`,
  тело и вложения в S3, строки в Postgres, `publish deliver`;
- `deliver` (`retry: 2`) — HMAC-SHA256 по полям письма, `Sink.deliver`; любой
  не-2xx — исключение, очередь повторяет, после третьей попытки — dead letter.

## Модель данных

- `Mailbox(id, address, secret, cursor, active)` — `address` уникален;
  `cursor` — позиция в инбоксе провайдера;
- `Route(id, mailboxId, topic, fromContains, subjectContains)` — первое
  совпадение выигрывает, иначе письмо получает `topic = unmatched` и статус
  `ignored` (оно всё равно сохраняется и видно в API);
- `Message(id, mailboxId, externalId, ..., bodyKey, digest, status)` —
  `digest` = sha256 тела, `status`: `ingested → delivered | failed`, `ignored`;
- `Attachment(id, messageId, name, contentType, key, bytes, sha256)` — объект в
  S3, размер и дайджест считаются по декодированным байтам;
- `Delivery(id, messageId, topic, status, attempts, lastError)` — журнал
  попыток; replay создаёт новую строку, старые остаются историей.

## Запуск

```bash
arcod check
arcod build --impl
arcod run --impl --port 8098      # Postgres + Redis + MinIO
./smoke.sh                        # сборка, запуск, моки, HTTP-проверки
arcod run --down --impl           # остановка
```

`smoke.sh` сам поднимает моки `inbox` и `sink` в сети compose и проверяет:
маршрутизацию, S3-тело и вложение, HMAC-подпись, дедуп по курсору, две
неудачи подряд и успех с третьей попытки, dead letter после трёх неудач,
replay и 409 на повторный replay, 404 на чужие id. Последняя строка — `PASS`.

## Опыт использования Arc

Что легло хорошо:

- `job ... { on: events.x, retry: N }` — ровно то, что нужно почтовому
  конвейеру: два независимых консьюмера, повтор и dead letter без кода;
- внешний сервис как `external service ... : http` — почтовый провайдер и
  подписчик остаются «чужими»: адрес в `bind`, тело — типизированный вызов;
- `sql` на Postgres: миграции, `find` с `order`/`limit`, `count` — без
  сюрпризов; пример заодно служит регрессией для #43 (outbox-DDL);
- идемпотентность собирается из языка: строки + `(mailboxId, externalId)`
  переживают повтор задания, курсор обновляется последним.

Чего не хватило (и что с этим сделано):

- **нет cron/timer** — «опрос раз в минуту» не выразить; `poll` вызывается
  снаружи (в тесте — smoke, в бою — cron/планировщик). Открытый #12, #40
  закрыт как дубликат;
- **`mail` как эффект недоступен** — провайдер `mailpit` из таблицы убран
  (#33), почта в примере — внешний HTTP-провайдер, а не `uses mail`;
- **`blobPut` только текст** — вложения лежат base64, размер и sha256
  считаются вручную (#48);
- **dead letter только читается** — после replay старая запись остаётся
  навсегда, снять её нечем (#49);
- **`impl/*.mjs` склеиваются в один модуль** — одноимённые хелперы в двух
  файлах валят сборку `A093` (#39); пришлось префиксовать (`mailboxHex`,
  `ingestHex`, `deliverHex`);
- у `io.remote` не-2xx — это исключение, а не `{status, body}`: ветка
  `if (reply.status >= 400)` недостижима, ошибку ловим `try/catch` (#45).

Статус примера: **done** — все проверки smoke проходят на чистом состоянии
(arcod `9233d2d`, Postgres 16, Redis 7, MinIO).
