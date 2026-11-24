# 036 — Центр уведомлений

Система рассылок: шаблоны, кампании, fan-out по получателям, доставка через
внешний почтовый шлюз, ретраи с dead letter, аналитика по дням и выгрузка CSV
в объектное хранилище.

Это не «сервис + kv»: в работе участвуют **четыре внешние системы** (MySQL,
Redis-очередь, S3 и почтовый шлюз вендора) и **два фоновых консьюмера**, а
HTTP-ответ не ждёт ни одного письма.

## Компоненты

```
                 POST /v1/campaigns
                        |
                        v
  +------------------+  insert campaign + audience rows, publish fanout
  |  Notifications   |----------------------------------------+
  |  (http service)  |                                        |
  +------------------+                                        v
        |   ^                                          +-------------+
        |   | GET view/report/daily/dead               | Redis queue |
        |   |                                          | fanout      |
        v   |                                          | deliver     |
  +-----------+   +-----------+                        +-------------+
  |  MySQL    |   |    S3     |                              |
  | templates |   | reports/  |         +--------------------+--------------------+
  | campaigns |   | <id>.csv  |         |                                         |
  | audience  |   +-----------+         v                                         v
  | deliveries|                  job fanout(campaignId)                 job deliver(deliveryId)
  | day stats |                  rows -> one per address                render -> Mailer.send
  +-----------+                  publish deliver                       sent/failed -> stats
                                                                              |
                                                                              v
                                                                  +----------------------+
                                                                  |  mail gateway (mock) |
                                                                  |  POST /api/v1/send   |
                                                                  +----------------------+
```

Поток одной кампании:

1. `POST /v1/campaigns` пишет кампанию и получателей в MySQL и публикует
   `fanout` — публикация и вставка уходят одной транзакцией через outbox.
2. Консьюмер `fanout` превращает получателей в строки `Delivery` (по одной на
   адрес, повторный запуск ничего не дублирует) и публикует `deliver` на каждую.
3. Консьюмер `deliver` рендерит `{{name}}`/`{{email}}`/`{{campaign}}`, вызывает
   `Mailer.send`, фиксирует статус и обновляет дневную статистику.
4. Ошибка отправки возвращает сообщение в очередь (retry 2), после третьей
   попытки оно уходит в dead letter и читается через `GET /v1/dead`.
5. Когда не осталось `queued`/`retrying`, кампания становится `done`.
6. `GET /v1/campaigns/:id/report` собирает CSV и кладёт его в S3; тот же файл
   читается обратно через `GET /v1/campaigns/:id/report.csv`.

## Компонент → provider

| Компонент | Capability | Provider | Как объявлен |
|-----------|------------|----------|--------------|
| Шаблоны, кампании, получатели, доставки, дневные счётчики | `sql` | mysql | `bind store -> mysql(host: "db", port: 3306)` |
| Очередь `fanout`/`deliver`, dead letter | `queue` | redis | `bind events -> redis(host: "queue", port: 6379)` |
| CSV-отчёты кампании | `blob` | s3 | `bind files -> s3(host: "s3", port: 9000)` |
| Почтовый шлюз вендора | `endpoint` | endpoint (external) | `bind Mailer -> endpoint(url: "http://mailer:9096")` |
| Идентификаторы | `ids` | local | `bind uuid -> local` |

Провайдеров, которые поднимают контейнер: три (mysql, redis, s3); почтовый
шлюз — внешний сервис, в smoke он подменён моком `mock/mailer.mjs` в той же
compose-сети под именем `mailer`.

## API

| Метод и путь | Что делает |
|--------------|-----------|
| `POST /v1/templates` | создать шаблон (`code` уникален, дубль — 409) |
| `GET /v1/templates` | список шаблонов |
| `POST /v1/campaigns` | кампания + аудитория (до 200 адресов) → 201, сразу `queued` |
| `GET /v1/campaigns/:id` | кампания + счётчики total/sent/failed/queued |
| `GET /v1/campaigns/:id/deliveries` | строки доставок |
| `GET /v1/campaigns/:id/report` | CSV в S3, ответ: ключ и итоги |
| `GET /v1/campaigns/:id/report.csv` | тот же CSV через сервис |
| `GET /v1/daily` | счётчики по дням и шаблонам |
| `GET /v1/dead` | dead letter очереди `deliver` |
| `POST /v1/admin/fanout/:id` | повторная публикация fan-out (проверка идемпотентности) |

## Запуск

```bash
arcod check
arcod build --impl --port 8094
arcod run --impl --port 8094
./smoke.sh
```

С остановкой:

```bash
arcod run --down --impl
# или
docker compose -f .arcod/build/docker-compose.yml down -v
```

`smoke.sh` сам поднимает мок почтового шлюза в compose-сети, проходит весь
поток и печатает `PASS`. Порт сервиса — `8094`, мока — `9096`, оба
переопределяются переменными `PORT` и `MAIL_PORT`.

## Опыт использования Arc

Что модель дала бесплатно:

- fan-out и доставка — это `job ... { on: events.topic, retry: 2 }`, рантайм
  сам стартует консьюмеры до HTTP-сервера, дренирует их на SIGTERM, повторяет
  упавшее сообщение и уносит его в dead letter. Ни одной строки про очереди в
  `impl/*.mjs`;
- публикация события и вставка кампании идут одной транзакцией через outbox —
  крах между ними не теряет кампанию;
- счётчики кампании — `io.count` с `where`, дневная аналитика — обычные строки
  `DayStat`, без OLAP-движка;
- CSV в S3 — `io.blobPut`/`io.blobGet`, тип `bytes` объявляется на месте
  (`type Csv = bytes(min: 1, max: 512kb)`).

Чего не хватило и что выяснилось:

1. **`olap` (clickhouse) объявлен провайдером, но адаптера нет.** Идея 036
   предполагала аналитику в OLAP; `uses analytics: olap` теперь честно падает
   на check (`capability olap has no effects and no adapter`, #26). Аналитика
   сделана строками в MySQL, а `clickhouse` в compose не поднимается.
2. **postgres + queue не собирается на чистом состоянии.** Outbox-DDL для
   postgres содержит запятую перед `)` (`src/migrate.ts`), postgres отвечает
   `syntax error at or near ")"`, сервис не проходит миграции. Пример на MySQL,
   потому что postgres-путь заблокирован. [#43](https://github.com/chubakur/arcod/issues/43).
3. **Поля сообщения должны быть объявлены параметрами job.** `job fanout(campaignId)`
   получает только `campaignId`; `audience`, положенная в payload, в теле не
   появляется. Это не баг, но неочевидно: пришлось хранить аудиторию отдельной
   таблицей — в итоге даже лучше, потому что перезапуск консьюмера её не теряет.
4. **`io.queueDead` возвращает разобранные сообщения** (`{payload, attempts,
   lastError}`), но публичного HTTP-снимка dead letter нет — пришлось заводить
   операцию `dead()` с эффектом `events.dead`.

## Замечания по эксплуатации

- Адрес на домене `bounce.test` мок отклоняет с 500: так smoke детерминированно
  проходит весь путь «три попытки → dead letter».
- `Delivery` — ключ идемпотентности: повторная доставка того же сообщения
  проверяет статус `sent` и не шлёт письмо второй раз.
- Дневная статистика обновляется только на терминальном переходе (`sent` или
  третья неудача), поэтому ретраи не завышают цифры.
