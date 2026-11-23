# 014 — Видеоплатформа

Мини-платформа публикации видео: источник кладётся в S3, тяжёлая работа уходит
в очередь, два консьюмера доводят видео до готовности и сообщают наружу
вебхуком. Это система из четырёх внешних сервисов, а не «сервис + kv»:
у каждого шага своя цена отказа, и отказ одного шага не отменяет остальные.

## Что происходит

```
клиент ──POST /v1/videos──► сервис ──PUT──────► MinIO (source)
                               │
                               └──publish───► Redis queue (transcode)
                                                  │
                                          job transcode
                                     GET source ◄─┤
                                     PUT 720p/480p ► MinIO
                                     INSERT rendition ► MySQL
                                     UPDATE video=ready
                                                  │
                                           publish ready
                                                  │
                                           job notify ──POST──► вебхук
                                                          └ INSERT delivery ► MySQL
```

- **Источник** пишется в S3 до ответа: строка со ссылкой на несуществующий
  объект — это ложь, которую потом не отличить от потери данных.
- **Транскод** идёт в консьюмере, по одному сообщению на видео. Пресеты
  выполняются по очереди внутри сообщения: так прогресс линеен, а ретрай
  повторяет ровно то, что не доделано (готовая rendition-строка — доказательство,
  что объект уже в S3).
- **Уведомление** — отдельный консьюмер: сломанный вебхук стоит ретрая и строки
  в `delivery`, а не застрявшего пайплайна.
- **Ретрай** разрешён только для `failed` и обнуляет счётчик попыток: это
  продуктовое решение, а не ремонт.
- **Sweep** возвращает в очередь строки, застрявшие в `transcoding` дольше
  минуты (умерший консьюмер), и ничего не делает, если застрявших нет.

## Компонент → provider

| Компонент | Возможность | Провайдер (dev) | Зачем |
|-----------|-------------|-----------------|-------|
| `store` | `sql` | `mysql:8.4` | видео, renditions, delivery — состояние и переходы |
| `events` | `queue` | `redis:7` | `transcode` и `ready`, at-least-once, ретраи |
| `files` | `blob` | `minio` (s3) | источник, пресеты, превью |
| `Hook` | `endpoint` | мок `mock/hook.mjs` | внешний вебхук о готовности |
| `uuid` | `ids` | `local` | идентификаторы |

Внешние системы в `docker-compose` (генерируется из `bind`): **MySQL, Redis
(очередь), MinIO** — три контейнера плюс мок вебхука на хосте. `ids` — это
собственный рантайм компилятора, контейнера нет.

## API

| Метод и путь | Что делает | Эффекты |
|--------------|-----------|---------|
| `POST /v1/videos` | загрузка: байты в S3, событие в очередь | `store.find/insert`, `files.put`, `events.publish`, `uuid.new` |
| `GET /v1/videos/:id` | прогресс: видео + renditions | `store.fetch/find` |
| `GET /v1/videos` | страница библиотеки | `store.find` |
| `GET /v1/videos/:id/source` | исходные байты через сервис | `store.fetch`, `files.get` |
| `GET /v1/renditions/:id/file` | байты пресета | `store.fetch`, `files.get` |
| `POST /v1/videos/:id/retry` | повтор только для `failed` | `store.fetch/update`, `events.publish` |
| `POST /v1/admin/sweep` | вернуть застрявшие в очередь | `store.find/update`, `events.publish` |
| `GET /v1/stats` | сводка библиотеки | `store.find` |
| job `transcode` | `events.transcode` | `files.get/put`, `store.*`, `events.publish` |
| job `notify` | `events.ready` | `Hook.ready`, `store.insert` |

Статусы видео: `queued → transcoding → ready | failed`. Checksum уникален:
повторная загрузка тех же байтов — `409 Conflict` с `videoId` победителя.
Битый источник (`CORRUPT…`) сжигает бюджет из трёх попыток
(`retry: 2`) и паркуется в `failed`, а не висит в `transcoding`.

## Запуск

```bash
arcod check
arcod build --impl --port 8093
arcod run --impl --port 8093        # поднимет mysql, redis, minio
./smoke.sh                          # сборка + запуск + проверки, в конце PASS
arcod run --down --impl             # или docker compose -f .arcod/build/docker-compose.yml down -v
```

`smoke.sh` поднимает мок вебхука на 9098, прогоняет загрузку, готовность,
чтение байтов из S3, доставку вебхука, дубликат по checksum, битый источник,
ретрай, статистику и sweep. Если `arcod` не в PATH:
`ARCOD=/path/to/bin/arcod.mjs ./smoke.sh`.

## Опыт использования Arc

Что язык дал бесплатно:

- **Эффекты как контракт.** `effects` в операции и джобе — это одновременно
  разрешение, документация и материал для промпта. `deny net, fs, exec` не
  даёт «дописать сеть» в тело.
- **Одна спека — четыре системы.** `bind` породил compose с healthcheck, env,
  томами и миграциями; руками не написано ни строки compose.
- **Очередь и SQL как типы.** ``job transcode(videoId: VideoId)`` плюс
  `on: events.transcode` — это консьюмер с ретраями и dead-letter, а тело
  осталось обычным `impl`.
- **Уникальность в схеме.** `unique Video.checksum` дал 409 без единой проверки
  в коде и переживёт любого нового автора операции.
- **`bytes` и `blob`.** Источник и renditions читаются через сервис; ключи S3
  не утекают в контракт.

Что пришлось обходить (и почему):

- **Один консьюмер на видео.** Параллельные джобы и HTTP-запросы делят одно
  MySQL-соединение и обмениваются наборами строк (issue #36). Пока это не
  исправлено, дисциплина «одно сообщение — один владелец строки» дешевле, чем
  гонки; в README это записано как ограничение примера, а не как дизайн.
- **Счётчики вместо агрегатов.** `io.aggregate` документирован, но в рантайме
  отсутствует (issue #34): статистика считает страницу и складывает в JS.
- **Без `kv`.** `bind cache -> redis` поднимает контейнер, но `io.save/load`
  пишут в SQL-таблицу `arcod_kv`, а `REDIS_URL` сервис не читает (issue #37),
  поэтому возможность `kv` из спеки убрана: лишний контейнер без эффекта —
  это ложь в таблице провайдеров.
- **Нет presigned URL и листинга бакета.** Раздача — только через сервис;
  «прямая загрузка в S3» и уборка осиротевших объектов (идея 033) без
  `blob.list`/`blob.sign` невыразимы.
- **Нет отложенных сообщений.** Пауза между попытками не выражается; ретраи
  идут сразу, поэтому «битый источник» детерминирован, а не «подождать и ещё
  раз». Это та же дыра, что и в 013.

## Проверки

`smoke.sh` на чистом состоянии (`arcod f0119d3`):

```
- health: ok (service + mysql + redis queue + minio + webhook mock)
- upload: <id> queued, sourceKey videos/<id>/source
- consumer: 2 renditions, preview videos/<id>/preview
- blob: source and rendition round-trip through S3
- webhook: ready event delivered
- guard: duplicate checksum rejected with 409
- consumer: corrupt source failed after 3 attempts
- retry: ready -> 409, failed -> requeued and failed again
- stats: total=2 ready=1 failed=1
- sweep: ok, queued=0
PASS
```
