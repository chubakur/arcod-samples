# 012 — Field dispatch (диспетчер выездов)

Система сервисной компании: заявки на выезд мастера, подбор техника по городу
и навыку, фотоотчёт в S3, уведомление клиента через внешний шлюз. Заявка
создаётся по HTTP и сразу получает ответ; назначение техника и уведомление —
фоновые консьюмеры очереди.

## Схема

```
             POST /v1/tickets                    ┌──────────────┐
 клиент ───────────────────────────► FieldDispatch ─── insert ──► MySQL (ticket, tech)
             GET  /v1/tickets/:id         │      │
             POST .../complete            │      ├── blobPut ───► MinIO (ticket/<id>/*)
                                          │      │
                                          │      └── publish ───► Redis queue
                                          │                          │
                                          │        ┌─────────────────┘
                                          │        ▼
                                          │   dispatch (job) ──► Router.offer  (HTTP)
                                          │        │                 │
                                          │        └── update ticket ◄┘
                                          │
                                          └── notify (job) ───► Router.notify (HTTP)

 Router — внешний сервис (маршрутизация + SMS). В dev его изображает
 mock/router.mjs на :9098, в проде — чужой сервис, адрес из ROUTER_URL.
```

## Компонент → provider

| Компонент | Возможность | Provider (dev) | Что делает |
|-----------|-------------|----------------|------------|
| Заявки, техники | `sql` | MySQL 8.4 | таблицы `ticket`, `tech`, миграции из модели |
| Очередь задач | `queue` | Redis 7 | `dispatch`, `notify`; at-least-once, retry, dead letter |
| Фотоотчёты | `blob` | MinIO (S3) | `ticket/<id>/<key>` |
| Маршрутизация и SMS | `endpoint` (external service) | mock HTTP :9098 | `POST /v1/offers`, `POST /v1/notify` |
| ID | `ids` | local | uuid заявок и техников |

Четыре внешние системы (MySQL, Redis, S3, Router) и один фоновый консьюмер
на каждый job.

## API

| Метод и путь | Операция | Что делает |
|--------------|----------|------------|
| `POST /v1/tickets` | `open` | создаёт заявку, считает SLA по приоритету, публикует `dispatch` |
| `POST /v1/technicians` | `registerTech` | регистрирует техника с навыками |
| `GET /v1/tickets/:id` | `get` | заявка по id |
| `GET /v1/tickets?city=&status=` | `board` | очередь заявок, `order dueAt asc` |
| `GET /v1/stats?city=` | `stats` | `count` по queued/assigned/done |
| `POST /v1/tickets/:id/complete` | `complete` | пишет фото в S3, закрывает заявку, публикует `notify` |
| `GET /v1/tickets/:id/report` | `report` | читает фото из S3 |

Приоритет 1/2/3 → SLA 4/12/48 часов. Назначение идемпотентно: повторная
доставка сообщения не назначает второго техника (статус уже `assigned`).

## Запуск

```bash
arcod check
arcod build --impl --port 8097
arcod run --impl --port 8097      # mysql + redis + minio
./smoke.sh                        # сборка, запуск, HTTP-проверки, PASS
```

Остановка: `arcod run --down --impl` или
`docker compose -f .arcod/build/docker-compose.yml down -v`.

## Опыт использования Arc

- `io.count(entity, {where})` закрывает счётчики без сканирования — `stats`
  это три count-запроса, а не выборка всех заявок.
- `find` с `order`, `limit` и операторами (`eq/ne/in/gt/...`) хватило для
  доски заявок; keyset-курсор не понадобился, но он есть.
- Джобы получают параметр по имени (`input.ticketId`), публикация —
  `io.queuePublish('dispatch', id)`; связка «очередь + job» читается как
  один контракт, менять тело на транспорт не приходится.
- `external service` + `io.remote` хорошо изолируют чужой сервис: адрес
  приходит из окружения, в compose `localhost` переписывается на
  `host.docker.internal`, контейнер мока поднимать не нужно.
- Blob-ключи строятся в теле (`ticket/<id>/<key>`), модель их не знает —
  удобно, но нет декларации «сколько фото и какого размера»; ограничение
  живо только в коде.

## Чего не хватило (issue в chubakur/arcod)

- **postgres** — эмиттится pg-клиент, но SCRAM-рукопожатие падает:
  `08P01 malformed SCRAM message` (клиент шлёт client-first без `n,,`).
  Проект переведён на MySQL. [#29](https://github.com/chubakur/arcod/issues/29)
- **rabbitmq** — `bind events -> rabbitmq` поднимает брокер, но рантайм
  слушает только Redis/in-memory; job исполнялся в процессе и терял
  сообщения при рестарте. Переведено на `bind events -> redis`.
  [#30](https://github.com/chubakur/arcod/issues/30)
- **list в сущности** — `list<string>` не вставляется в MySQL JSON
  (`3144 binary charset`); навыки и ключи фото хранятся строкой через
  запятую. [#31](https://github.com/chubakur/arcod/issues/31)
- **io.remote** — возвращает `{status, body}`, а README показывает тело;
  на этом потерялся час отладки. [#32](https://github.com/chubakur/arcod/issues/32)
- **mail** — `arcod providers` обещает mailpit, но у capability нет
  эффектов (A076), поэтому уведомления ушли во внешний HTTP-шлюз.
  [#33](https://github.com/chubakur/arcod/issues/33)
- **cron внутри job** — расписание есть только у `workflow`, а workflow в
  v0.1 не исполняется (W022); периодический обход SLA пришлось оставить
  оператору/внешнему планировщику.
