# 041 — Delivery zones

Система тарификации доставки: полигоны зон и тарифы живут в Postgres, точка
запроса разрешается в зону (point-in-polygon), цена считается по базовому тарифу
и километражу, адрес подтягивается из внешнего геокодера. Каждое изменение зоны
уходит в очередь, фоновый consumer пишет снапшот зоны в S3 и ставит
`reindexedAt` — только после этого снапшот доступен по API.

## Компоненты и провайдеры

| Компонент | Provider | Где живёт |
|---|---|---|
| `store` — зоны, котировки | `sql` → postgres | compose `db` |
| `zoneCache` — разрешённая зона и геокод по координатам | `kv` → `arcod_kv` в той же SQL-БД | compose `db` (см. «Опыт») |
| `events` — очередь `reindex` | `queue` → redis | compose `redis` |
| `files` — снапшоты зон | `blob` → s3 (MinIO) | compose `s3` |
| `Geocoder` — reverse geocoding | `endpoint` → внешний HTTP | `mock/geocoder.mjs` на хосте, `:9096` |

В docker-compose три внешние системы: **Postgres**, **Redis**, **S3**. Геокодер —
четвёртая внешняя система, но это чужой сервис, поэтому он поднимается моком на
хосте и пробрасывается в контейнер как `host.docker.internal:9096`.

## Схема

```
            POST /v1/zones                       POST /v1/quotes
                  |                                     |
                  v                                     v
        +-------------------+                 +-------------------+
        |  DeliveryZones    |  find polygon   |  DeliveryZones    |
        |  addZone          |<----------------|  quote            |
        +---------+---------+                 +----+---------+----+
                  |                              |         |
        insert Zone (Postgres)          kv cache |         | Geocoder.reverse
                  |                     (arcod_kv)|         v
                  | outbox -> queue (Redis)       |   mock geocoder :9096
                  v                              v
        +-------------------+              insert Quote (Postgres)
        | job reindex       |
        | fetch Zone        |
        | blobPut snapshot  |----> S3: zones/<id>.json
        | update reindexedAt|
        +-------------------+
```

## API

| Метод | Путь | Что делает |
|---|---|---|
| POST | `/v1/zones` | создать зону: `name`, `polygon` (JSON-массив `[[lng,lat],...]`), `basePrice`, `perKm` |
| GET | `/v1/zones` | список зон |
| POST | `/v1/quotes` | котировка: `lat`, `lng`, `distanceKm`; 404 если точка вне полигонов |
| GET | `/v1/quotes/:id` | котировка по id |
| GET | `/v1/zones/:id/snapshot` | снапшот из S3; 404 пока consumer не отработал |
| GET | `/v1/stats` | число зон, котировок и активных зон |
| GET | `/healthz` | health провайдера |

Ошибки: `400 Invalid` (полигон/координаты/тариф), `404 NotFound` (точка вне зон,
нет снапшота), `409 Conflict` (имя зоны занято), `503 Unavailable` (геокодер не
ответил).

## Запуск

```bash
# 1. внешний геокодер (порт 9096)
GEO_PORT=9096 node mock/geocoder.mjs &

# 2. проверка, сборка, запуск
arcod check
arcod build --impl
arcod run --impl --port 8093

# 3. end-to-end проверки (сборка + запуск + HTTP + consumer + S3)
./smoke.sh
```

Остановка:

```bash
arcod run --down --impl
# или
docker compose -f .arcod/build/docker-compose.yml down -v
```

`smoke.sh` сам запускает мок геокодера, пересобирает проект и в конце печатает
`PASS`. Порт по умолчанию 8093, мок — 9096; оба переопределяются через `PORT` и
`GEO_PORT`.

## Опыт использования Arc

Что легло хорошо:

- `sql` + `queue` + `blob` + `endpoint` закрывают систему целиком: зоны и
  котировки — строки, событие `reindex` — очередь, снапшот — объект, геокодер —
  внешний контракт.
- `job reindex` с `on: events.reindex` и `retry: 2` — ровно тот consumer,
  который нужен: запрос не ждёт S3, а снапшот появляется асинхронно. `smoke.sh`
  проверяет именно это, опрашивая `/v1/zones/:id/snapshot`.
- `unique Zone.name` даёт 409 без ручной таблицы резерваций (с оговоркой ниже).
- `endpoint` сам превращает `localhost` в `host.docker.internal`, мок на хосте
  работает без ручной правки compose (проверено после #42).

Чего не хватило:

- **kv рядом с sql.** `uses store: sql` + `bind zoneCache -> redis` не проходит
  check (A094): alias уходит в `arcod_kv` внутри SQL, а не в Redis. Поэтому
  Redis в этой системе — только очередь, а кэш зон и геокода честно лежит в
  Postgres. Для настоящего кэша нужен либо отдельный kv-сервис, либо отказ от
  SQL-store (см. #37, #40).
- **Сбой unique-вставки вешает сервис.** Повторный `POST /v1/zones` с тем же
  именем не отвечает и останавливает `/healthz`; воспроизведено на чистом
  состоянии, заведено [#54](https://github.com/chubakur/arcod/issues/54).
  Обход в примере: предварительный `io.find` по имени, `unique` оставлен
  арбитром гонки.
- **Нет геотипа и пространственных предикатов.** Полигон хранится строкой,
  point-in-polygon и площадь считаются вручную в `impl/quote.mjs`. Для
  production нужен `geometry`/PostGIS и `ST_Contains`, иначе валидация и
  пересечения зон остаются на совести кода.
- **Конверт kv не описан.** `io.save`/`io.load` работают с `{ b, h }`, а не с
  голым значением; это видно только в сгенерированном коде (#52).
- **Тело object-аргумента.** Операция с единственным аргументом-типом
  (`op addZone(input: ZoneInput)`) ждёт тело `{"input": {...}}`, а не плоский
  объект. В примере параметры развёрнуты в обычные аргументы — API чище.
