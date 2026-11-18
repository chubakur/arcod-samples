# 002 — Webhook Inbox

Приём вебхуков от внешних сервисов: идемпотентность по ключу отправителя,
асинхронная доставка подписчику через очередь, повторы и dead-letter,
ручная повторная доставка.

## Что умеет

- `POST /v1/hooks/:source` — принять событие. Тело: `key` (ключ
  идемпотентности), `eventType`, `payload` (строка, обычно JSON) и
  необязательный `failFirst` — сколько первых попыток доставки «сломать»
  (для демонстрации повторов). Повтор с той же парой `(source, key)`
  возвращает то же событие с `duplicate: true` и не публикует его заново.
- `GET /v1/events/:id` — событие: статус, число попыток, время доставки.
- `GET /v1/events?source=&status=&limit=` — список, свежие сверху.
- `POST /v1/events/:id/redeliver` — ручная повторная доставка: счётчик
  попыток и «поломка» сбрасываются, событие снова уходит в очередь.
- `GET /v1/stats` — счётчики по статусам.

Статусы: `pending` → `retrying` (попытка не удалась, будет повтор) →
`delivered` либо `dead` (бюджет повторов исчерпан, сообщение уходит в DLQ).

## Модель

`Event` — одно принятое событие: `id`, `source`, `key`, `eventType`,
`payload`, `status`, `attempts`, `failFirst`, `receivedAt`, `deliveredAt`.
Ключ идемпотентности хранится отдельной записью `k:<source>:<key> → eventId`
в том же kv.

`job deliver(eventId)` — консьюмер очереди `deliveries`, `retry: 3`.
Тело увеличивает `attempts`, пишет статус и, если `attempts <= failFirst`,
возвращает `{ error: 'Transient' }` — runtime сам повторяет сообщение, а после
бюджета кладёт его в DLQ. Повторная доставка идемпотентна на уровне факта:
одно событие — одна запись, меняются только `attempts`/`status`.

## Запуск

```bash
arcod check
arcod build --impl
arcod run --impl --port 8092   # http://localhost:8092/healthz
./smoke.sh                     # полный прогон с проверками
```

Остановка: `arcod run --down --impl`.

`store` и `events` привязаны к разным redis-хостам (`kv` и `queue`):
если указать один хост, генератор compose выдаёт дубликат сервиса — issue #5.

## Пример

```bash
curl -sS -X POST localhost:8092/v1/hooks/github \
  -H 'content-type: application/json' \
  -d '{"key":"evt-42","eventType":"push","payload":"{\"ref\":\"main\"}"}'
# {"event":{...,"status":"pending","attempts":0},"duplicate":false}

sleep 1
curl -sS localhost:8092/v1/events/<id> | jq '{status,attempts}'
# {"status":"delivered","attempts":1}

# повтор того же ключа
curl -sS -X POST localhost:8092/v1/hooks/github \
  -H 'content-type: application/json' \
  -d '{"key":"evt-42","eventType":"push","payload":"{}"}' | jq .duplicate
# true
```

## Опыт использования Arc

- **Очередь и job читаются хорошо.** `job` с `on:`/`retry:` и
  `io.queuePublish` — компактно; весь lifecycle (ack/nack, requeue, DLQ)
  реально живёт в runtime, тело остаётся функцией сообщения.
- **Идемпотентность руками.** Готового atomic put-if-absent в kv нет:
  проверка `io.load` + `io.save` не атомарна, две одновременные доставки
  одного ключа теоретически могут создать два события. Для примера
  последовательных повторов достаточно; для продакшена нужен SETNX/atomic
  put-if-absent, которого в kv сейчас нет.
- **issue #5:** два capability на одном `redis(host: ...)` дают два одинаковых
  сервиса в `docker-compose.yml`, `arcod run` не парсит YAML. Обход — разные
  хосты (`kv`, `queue`), как здесь.
- **issue #6:** sandbox запрещает `io.fetch(...)`, принимая его за глобальный
  `fetch`. Пришлось читать событие через `io.find('Event', { where: { id } })`.
- **issue #7:** `io.queueDead('deliveries')` на redis роняет процесс
  (`unexpected RESP type: *`), поэтому эндпоинта чтения DLQ в примере нет:
  статус `dead` в API повторяет состояние брокера.
- **issue #8:** job с одним параметром получает весь объект сообщения, а не
  поле. Поэтому в очередь публикуется голый `eventId` строкой; с объектом
  `{ eventId }` тело увидело бы `{ eventId: { eventId } }`.
- `W012` (нет examples у операций) — известное ограничение, issue #3:
  литерал списка в examples записать нельзя.
