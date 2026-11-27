# 047 — Incident response (дежурства и инциденты)

Система реагирования на инциденты: у сервисов есть дежурные смены, монитор
шлёт алерты, повторный алерт в окне пяти минут складывается в уже открытый
инцидент, дежурный подтверждает (ack) и закрывает его, просроченный ack
эскалируется, а после закрытия фоновый консьюмер собирает постмортем в S3.
Живой фид инцидентов идёт по websocket.

Это не «сервис + kv»: состояние в PostgreSQL, очередь в Redis, артефакты в
MinIO, поток событий — websocket, плюс два фоновых консьюмера и отдельный
SLA-sweep.

## Компоненты

```
             POST /v1/alerts
 monitor ───────────────────┐
                            ▼
                    ┌───────────────┐        ┌────────────────────┐
                    │  Incidents    │───────▶│ PostgreSQL          │
                    │  (HTTP, impl) │        │ services, shifts,   │
                    │               │        │ incidents, events   │
                    └───┬───────┬───┘        └────────────────────┘
        queuePublish    │       │  blobPut/Get
      (notify,          │       ▼
       postmortem)      │   ┌─────────┐
                        │   │ MinIO   │  postmortems/<id>.md
                        ▼   └─────────┘
                 ┌─────────────┐
                 │ Redis lists │──▶ job notify ──────▶ websocket service:<id>
                 │  (queue)    │──▶ job postmortemDoc
                 └─────────────┘
```

### Компонент → provider

| Компонент | Provider | Роль |
|-----------|----------|------|
| Incidents API + state | `postgres` | services, shifts, incidents, incident_events |
| Очередь notify / postmortem | `redis` | Redis lists, at-least-once, dead-letter на тему |
| Постмортемы | `s3` (minio) | markdown-`postmortems/<incidentId>.md` |
| Live-фид | `websocket` | топик `service:<serviceId>` |
| Идентификаторы | `local` (ids) | UUID записей и событий |

Внешние системы в docker-compose: **PostgreSQL 16**, **Redis 7**, **MinIO**.
Четвёртый провайдер — websocket (транспорт внутри сервиса).

## Модель

- `Service` — имя (уникально), tier, ссылка на runbook.
- `Shift` — интервал дежурства; пересечения запрещены операцией (409).
- `Incident` — открытый/подтверждённый/закрытый инцидент, `dedupCount`,
  `escalated`, `postmortemKey`.
- `IncidentEvent` — таймлайн: `opened`, `assigned`, `deduped`,
  `acknowledged`, `escalated`, `resolved` (append-only).

### Дедупликация

Окно — 5 минут от `openedAt` последнего незакрытого инцидента с тем же
`fingerprint` у того же сервиса. Повтор не создаёт вторую запись: растёт
`dedupCount` и в таймлайн добавляется `deduped`. Окно реализовано запросом
`io.find` по SQL, потому что связать `kv`-алиас с `sql`-хранилищем в одном
сервисе нельзя (`A094`, issue #63) — см. «Опыт использования Arc».

### SLA и эскалация

| Severity | SLA до ack |
|----------|------------|
| SEV1 | 5 минут |
| SEV2 | 15 минут |
| SEV3 | 60 минут |
| SEV4 | 4 часа |

`POST /v1/sweep` находит открытые инциденты без ack старше SLA, один раз
помечает их `escalated`, пишет событие и повторно ставит `notify` в очередь.
Sweep вызывает внешний раннер: job в Arcod — это консьюмер очереди, а не cron.
Повторный sweep того же инцидента ничего не делает (проверяется `escalated`).

### Консьюмеры

- `notify(incidentId)` — находит смену, покрывающую `openedAt`, назначает
  дежурного, пишет `assigned` (или `unassigned`) и публикует событие в
  websocket. Повторная доставка находит `assigned` и выходит.
- `postmortemDoc(incidentId)` — рендерит markdown (шапка + summary + таймлайн),
  кладёт в S3 и пишет `postmortemKey`. Повторная доставка видит ключ и не
  делает второй объект.

## API

| Метод | Путь | Что делает |
|-------|------|------------|
| POST | `/v1/services` | создать сервис; дубль имени — 409 |
| POST | `/v1/services/:serviceId/shifts` | добавить смену; пересечение — 409, обратный интервал — 400 |
| GET | `/v1/services/:serviceId/on-call?at=` | кто дежурит сейчас/в момент `at` |
| POST | `/v1/alerts` | принять алерт: dedup или новый инцидент + `notify` |
| GET | `/v1/incidents?status=open&limit=` | список инцидентов (status=all — все) |
| GET | `/v1/incidents/:id` | инцидент + таймлайн |
| POST | `/v1/incidents/:id/ack` | подтвердить; повторный ack идемпотентен, после resolve — 409 |
| POST | `/v1/incidents/:id/resolve` | закрыть и поставить `postmortem`; повтор — 409 |
| POST | `/v1/sweep` | эскалировать просроченные ack |
| GET | `/v1/incidents/:id/postmortem` | markdown из S3 |
| GET | `/v1/stats` | сервисы, open/acked/resolved, deduped, MTTA |
| GET | `/v1/dead` | dead-letter обеих тем |

Websocket: `ws://localhost:8095/ws?topic=service:<serviceId>`, события
`{type:"incident", event:"assigned"|"acknowledged"|"resolved", ...}`.

## Запуск

```bash
cd 047-incident-response
arcod check
arcod build --impl --port 8095
arcod run --impl --port 8095      # compose: db, queue, s3 + сервис
./smoke.sh                        # сборка, запуск, HTTP-проверки, PASS
arcod run --down --impl           # остановить и удалить тома
```

`smoke.sh` принимает `ARCOD` и `PORT`; при другом компиляторе:
`ARCOD=/path/to/arcod/bin/arcod.mjs ./smoke.sh`.

## Опыт использования Arc

Что легло хорошо:

- Контракт с `unique Service.name` дал 409 из коробки, без ручной проверки.
- Два консьюмера и два стора (`sql` + `blob`) описываются декларативно;
  идемпотентность пришлось писать руками (проверка `postmortemKey` и события
  `assigned`), но at-least-once больше ничего не требует.
- `io.find` с `where`, `order` и `limit` хватило для списка инцидентов,
  таймлайна и поиска смены; `io.count` — для статистики.
- `io.publish` в websocket и `io.queuePublish` в Redis — одинаково простые.

Чего не хватило (и что сделано вместо):

1. **kv вместе с sql в одном сервисе.** Изначально окно дедупа жило в
   `kv(ttl: 900s)`, но `check` отвергает такой алиас: `A094` — «alias seen is
   kv in Incidents, but that service stores in sql». Пришлось хранить окно в
   SQL (`io.find` + сравнение времени). Это лишает SQL-сервис TTL-кэша:
   дедуп-ключи и rate-limit без отдельного сервиса не сделать. Issue #63.
2. **Нет исходящего HTTP.** Уведомления ограничены websocket: позвонить в
   PagerDuty/Slack или отправить письмо из op/job нельзя (`net` только
   `deny`, `mail`-провайдера нет вовсе). Issue #60. Поэтому «notify» — это
   назначение + live-фид, а не реальная пейджинг-интеграция.
3. **Job не запускается по расписанию.** `workflow ... trigger cron` — это
   контракт для внешнего раннера; у `job` есть только `on: events.*`.
   Периодический SLA-sweep пришлось выставить операцией `POST /v1/sweep` и
   вызывать её снаружи (smoke делает это вручную). Issue #12 покрывает
   отложенный запуск, но не повторяющийся.
4. **Нет примеров в контракте (W012).** `check` даёт 12 предупреждений на
   12 операций; для примера-витрины это шум, но не блокер.
5. **Нет типа для «интервала».** Пересечение смен проверяется в теле
   операции; объявить `unique (serviceId, startsAt, endsAt)` нельзя, а
   constraint на диапазон язык не выражает.

## Известные ограничения

- Sweep не встроен в сервис: его должен вызывать cron/раннер.
- Уведомления не уходят наружу (нет `net`, нет `mail`).
- Дедуп — окно 5 минут; после закрытия инцидента тот же fingerprint откроет
  новый (это осознанно: рецидив — новый инцидент).
