# 011 — Metric lake (time-series ingestion)

Идея `010` из [IDEAS.md](../IDEAS.md): приём метрик партиями, минутный rollup,
холодный экспорт и retention. Это система из четырёх внешних точек: MySQL,
Redis, S3-совместимое хранилище и внешний сервис алертов.

## Что происходит

```
клиент ──POST /v1/metrics/:metric/points──► MetricLake (http)
                                             │ 1. валидация партии (≤120 точек)
                                             │ 2. Batch (metric, idem) — идемпотентность
                                             │ 3. Point[] в MySQL (hot, TTL 30d)
                                             │ 4. outbox → RPUSH rollup
                                             ▼
                                          Redis ──► rollup consumer (тот же сервис)
                                                       │ складывает точки в минуты
                                                       │ Bucket upsert (metric, slot)
                                                       │ если hi > Monitor.threshold
                                                       ▼
                                              Alerter (внешний HTTP)  ──POST /v1/alerts──► on-call

GET  /v1/metrics/:metric/series   ──► Bucket[] → шаг 60/300/900/3600, пропуски
POST /v1/metrics/:metric/export   ──► JSONL в S3 (ключ exports/<metric>/<id>.jsonl)
GET  /v1/exports/:id              ──► запись + тело из S3
POST /v1/admin/sweep              ──► удаление Point/Bucket старше горизонта + отчёт в S3
```

Консьюмер — единственный писатель в `Bucket`. Он читает партию (≤500 точек,
потолок адаптера), группирует по минутам и делает read-modify-write бакета.
Это осознанно последовательная модель: CAS/атомарного инкремента в Arcod нет
(issue #10), поэтому второй репликой консьюмера счётчики терялись бы.

## API

| Метод | Путь | Что делает | Ошибки |
|-------|------|------------|--------|
| POST | `/v1/metrics/:metric/points` | партия точек + `idem`; дубль возвращает тот же batch | 400 |
| GET | `/v1/metrics/:metric/series` | бакеты в `[from,to]` с шагом `step` | 400, 404 |
| GET | `/v1/metrics/:metric/stats` | сводка по всей метрике | 404 |
| PUT | `/v1/metrics/:metric/monitor` | порог алерта (upsert) | 400 |
| POST | `/v1/metrics/:metric/export` | JSONL бакетов в S3 | 400, 404 |
| GET | `/v1/exports/:id` | запись экспорта + тело | 404 |
| POST | `/v1/admin/sweep?horizonHours=24` | retention сырых точек и бакетов | 400 |

Точки принимаются не старше 30 дней и не более чем на 5 минут в будущем —
это защита от «часов в будущем», а не бизнес-правило.

## Компоненты и провайдеры

| Компонент | Роль | Capability | Provider |
|-----------|------|------------|----------|
| `store` | Batch, Point, Bucket, Monitor, Alert, ExportRec, outbox | `sql` | `mysql` 8.4 |
| `events` | очередь заданий `rollup` (доставка между процессами) | `queue` | `redis` 7 |
| `archive` | JSONL-экспорты и отчёты retention | `blob` | `s3` (minio) |
| `uuid` | идентификаторы | `ids` | local |
| `Alerter` | внешний сервис алертов (в smoke — `mock/alerter.mjs`) | `endpoint` | внешний HTTP |

Внешние системы в `docker-compose`: MySQL, Redis, MinIO и endpoint алертов
(последний поднимает smoke, в compose его нет — это чужой сервис).

## Запуск

```bash
arcod check
arcod build --impl --port 8096
arcod run --impl --port 8096        # mysql + redis + minio в compose, сервис в контейнере
./smoke.sh                          # сборка, старт, HTTP-проверки, PASS
arcod run --down --impl             # остановка (или docker compose ... down -v)
```

`smoke.sh` уважает `ARCOD` (по умолчанию `arcod`) и `PORT` (по умолчанию 8096).
Нужен `arcod` не старше `c72e338`: в старых сборках `unique T.(a, b)` ещё не
парсился. Если `npm link` отстаёт от `origin/main`, укажите свежий чекаут:
`ARCOD="node /path/to/arcod/bin/arcod.mjs" ./smoke.sh`.

Смоук проверяет: health, ingest, идемпотентность по `(metric, idem)`, rollup
через Redis-очередь, агрегаты (count/total/hi/mean), два алерта во внешний
endpoint, шаг 300, экспорт в S3 и чтение обратно, retention и типизированные
ошибки 400/404.

## Опыт использования Arc

Что получилось хорошо:

- `unique Batch.(metric, idem)` и `unique Bucket.(metric, slot)` дали
  идемпотентность и upsert бакета без самодельных индексов. Составной ключ
  работает (issue #13 действительно закрыт).
- Очередь на Redis действительно межпроцессная: задание публикуется в outbox,
  уходит в Redis и исполняется консьюмером сервиса. Это единственный пример в
  коллекции, где consumer не in-process (009/010 биндят rabbitmq и получают
  memory-драйвер).
- Один и тот же тип работает и как тело ответа, и как таблица: `Bucket`
  отдаётся в `Series.points`, `ExportRec` — в `ExportBundle`.

Чего не хватило (подробности — в issue):

1. **OLAP-провайдера нет в языке.** `clickhouse` объявлен провайдером
   `olap`, но capability `olap` отсутствует в `capabilities.ts`: `uses x: olap`
   не проходит `check`, эффектов и адаптера нет. Идея 010 просила OLAP; здесь
   холодный слой сделан через S3-экспорт, а ClickHouse не подключается.
   [issue #26](https://github.com/chubakur/arcod/issues/26)
2. **Типы-значения материализуются в таблицы.** Ответ внешнего сервиса
   `AlertAck { ok, id: string }` превратился в таблицу `alertack` с
   `PRIMARY KEY (id)` на `TEXT` и уронил миграции MySQL (`1170`). Пришлось
   переименовать поле в `ref`. Таблицы для `Receipt`, `Series`, `Sample` тоже
   создаются, хотя это только DTO.
   [issue #27](https://github.com/chubakur/arcod/issues/27)
3. **Один параметр job.** Рантайм передаёт в тело `{ batchId }`, а пример 009
   написан как `process(reportId, io)`, то есть получает объект и молча ничего
   не делает. Пришлось принимать оба вида; в 009 это, похоже, латентный баг.
   [issue #28](https://github.com/chubakur/arcod/issues/28)
4. **Нет таймеров/расписания** (#12): retention — ручной `POST /v1/admin/sweep`,
   а не фоновая задача. Планировщик пришлось бы делать снаружи.
5. **find только по равенству** (#20): `series` читает все бакеты метрики
   страницами по 500 и фильтрует диапазон в теле. Для настоящей time-series
   нужен range-scan по `slot`.
6. **Нет агрегатов/count** (#15): `stats` тоже собирается полным сканом.
7. **Нет CAS/атомарного инкремента** (#10): консьюмер обязан быть один.
8. **postgres сломан** (#24): поэтому MySQL, хотя для time-series он был бы
   естественнее.

Ограничения примера: TTL у `store` один на весь sql-capability, поэтому
retention всё равно руками; экспорт читает бакеты, а не сырые точки; тело
экспорта грузится в память целиком (для демо — десятки строк).
