# 048-support-desk — мультитенантный help desk

Система поддержки для нескольких компаний в одном развёртывании: у каждой
компании свой workspace, свои сотрудники и свои заявки. Вход — через Keycloak,
метаданные — в Postgres, вложения и выгрузки — в S3 (MinIO), фоновая работа —
три консьюмера в Redis.

Это не «сервис + kv»: здесь четыре внешние системы и три фоновых консьюмера.

## Схема

```
                 ┌──────────────┐
   клиент ──────►│  Desk (http) │──── SQL ──────► Postgres
   Bearer JWT    │  auth op     │──── blob ─────► MinIO
                 │              │──── queue ────► Redis
                 └──────┬───────┘                    │
                        │ JWKS                       ├─ triage  (назначение)
                 ┌──────▼───────┐                    ├─ notify  (уведомления)
                 │   Keycloak   │                    └─ exportRun (JSONL в S3)
                 └──────────────┘
```

Изоляция: каждая строка (Member, Ticket, Message, Attachment, Notification,
Audit, Export) несёт `tenantId`; каждая операция сначала находит членство
вызывающего в этом tenant и только потом читает или пишет.

## Компонент → provider

| Компонент | Provider | Что делает |
|-----------|----------|------------|
| Вход и токены | `identity` → keycloak | JWT проверяется по JWKS, `io.actor()` даёт id/name |
| Метаданные | `sql` → postgres | tenant, member, ticket, message, attachment, notification, audit, export |
| Вложения и выгрузки | `blob` → minio (s3) | текст вложений и JSONL-экспорт tenant |
| Очередь | `queue` → redis | события triage / notify / exportRun, dead-letter |
| Идентификаторы | `ids` → local | uuid для строк и объектов |

## API

Все операции, кроме `sweep` и `dead`, — `auth op`: без `Authorization: Bearer`
они отвечают `401`. Роли tenant-локальные: owner / agent / requester, они лежат
в таблице Member, а не в токене.

| Метод и путь | Кто | Назначение |
|--------------|-----|------------|
| `POST /v1/tenants` | any auth | создать workspace, вызывающий становится owner |
| `POST /v1/tenants/:id/join` | any auth | войти по invite-коду (идемпотентно) |
| `POST /v1/tenants/:id/promote` | owner | выдать роль agent/requester |
| `GET /v1/tenants` | any auth | мои workspace и роли |
| `POST /v1/tenants/:id/tickets` | member | создать заявку, priority и SLA из текста |
| `GET /v1/tenants/:id/tickets` | member | очередь; requester видит только свои |
| `GET /v1/tickets/:id` | member | заявка + публичная переписка + вложения |
| `POST /v1/tickets/:id/messages` | member | ответ; internal — только staff |
| `POST /v1/tickets/:id/assign` | staff | назначить agent/owner |
| `POST /v1/tickets/:id/resolve` | staff | закрыть; повтор — 409 |
| `POST /v1/tickets/:id/attachments` | member | текст в S3 + строка в SQL |
| `GET /v1/tickets/:id/attachments/:aid` | member | байты из S3 |
| `POST /v1/tenants/:id/export` | staff | поставить выгрузку в очередь |
| `GET /v1/tenants/:id/exports` | staff | список выгрузок |
| `GET /v1/tenants/:id/exports/:eid` | staff | скачать готовый JSONL |
| `GET /v1/notifications` | any auth | мои уведомления (`?unread=true`) |
| `POST /v1/notifications/:id/read` | owner строки | отметить прочитанным |
| `GET /v1/tenants/:id/stats` | staff | счётчики tenant |
| `GET /v1/tenants/:id/audit` | staff | аудит действий |
| `POST /v1/sweep` | public | SLA-прорыв, идемпотентно, вызывается снаружи |
| `GET /v1/dead` | public | dead-letter по трём консьюмерам |

### Консьюмеры

1. **triage** (`ticket.created`): выбирает staff-участника с наименьшим числом
   открытых заявок, назначает его, пишет audit и будит notify.
2. **notify**: по последнему сообщению создаёт уведомления второй стороне;
   id уведомления — `nt:<messageId>:<userId>`, повторная доставка ловится на
   unique primary key и не создаёт дубль.
3. **exportRun**: складывает все заявки tenant с перепиской в JSONL, пишет в S3
   и переводит строку Export в `ready`. Объект пишется раньше строки.

## Запуск

```sh
arcod check
arcod build --impl
arcod run --impl --port 8094
./smoke.sh          # полный прогон с чистого состояния, в конце PASS
arcod run --down --impl
```

Keycloak не публикует порт наружу: токен для ручных проверок добывается изнутри
compose-сети (так же делает `smoke.sh`):

```sh
docker compose -f .arcod/build/docker-compose.yml exec -T service node -e "
fetch('http://idp:8080/realms/arcod/protocol/openid-connect/token', {
  method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: 'grant_type=password&client_id=arcod-web&username=alice&password=alice'
}).then(r => r.json()).then(j => process.stdout.write(j.access_token))"
```

Пользователи realm `arcod`: `alice` (owner), `bob` (agent), `carol`
(customer), `dave` (второй tenant). Пароль совпадает с логином.

## Опыт использования Arc

Что сработало:

- `identity` + `auth op` действительно проверяют JWT по JWKS и дают
  `io.actor()`; guard 401/403 работает до тела операции.
- `rules { unique Tenant.slug }` и `unique Member.(tenantId, userId)` дают
  ожидаемый 409, идемпотентный join на этом держится.
- `io.find` с `where`, `order`, `limit`, `io.count` с `where` — хватает для
  очередей, счётчиков и пагинации без полного скана.
- Цепочка consumer → consumer (triage публикует notify) работает; повторная
  доставка notify не плодит уведомления благодаря детерминированному id.
- `io.blobPut`/`blobGet` для текста и NDJSON — без сюрпризов.
- `auth op` с tenant-ролями в SQL оказался удобнее realm-ролей: роль в одном
  workspace не протекает в другой.

Чего не хватило:

- **#64 (новый).** `auth op` без объявленного `error Unauthorized` проходит
  `check`, но анонимный запрос получает `500 Internal`, а не `401`:
  `authorize()` возвращает `Unauthorized`, которого нет в `ERRORS`. Пришлось
  объявлять `Unauthorized` и `on error Unauthorized` в каждой из 19 операций.
- **#48 (open).** `io.blobPut` принимает только string — вложения хранятся как
  текст; бинарные файлы пришлось бы кодировать в base64.
- **#12 (open).** у job нет cron-триггера, поэтому SLA-sweep — публичная
  операция `POST /v1/sweep`, её дёргает внешний runner.
- **#60 (open).** нет исходящего HTTP/почты: уведомления только внутри системы,
  письма и webhooks из job не отправить.
- **#63 (open).** TTL-кэш рядом с sql-сервисом недоступен (kv-алиас → A094);
  дедуп и «недавно видели» пришлось бы держать в SQL.
- `update` без предусловия (#58, open): два параллельных `assign` перетирают
  друг друга; в примере это осознанно оставлено на уровне «последний выиграл».

## Проверки smoke.sh

Аноним → 401; создание tenant, дубль slug → 409; неверный invite → 403;
идемпотентный join; заявка с priority high; triage назначает owner; notify
создаёт уведомление; promote только owner; assign только staff; internal-заметка
не видна requester; публичный ответ уведомляет; чтение чужого уведомления → 403;
вложение в S3 и чтение байт; export только staff, queued → 409 на скачивание,
готовый JSONL содержит заявку; статистика и audit; sweep один прорыв и
идемпотентный повтор; resolve и повторный resolve → 409; ответ клиента
переоткрывает; изоляция второго tenant; пустой dead-letter.
