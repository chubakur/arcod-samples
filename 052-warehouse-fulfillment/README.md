# 052-warehouse-fulfillment: склад и отгрузка (3PL)

Система складской логистики: каталог SKU, приёмка партий с сроком годности,
заказы, резервирование по FEFO, задания на сборку, отгрузка через внешнюю
службу доставки и планировщик, который списывает просрочку и предлагает
закупку. Это не «сервис + kv»: пять внешних систем, четыре фоновых
консьюмера и поток событий склада.

Ключевое разделение: HTTP-запрос не трогает остатки. createOrder пишет
заказ и строки, публикует id в очередь; распределение по партиям, документ
на сборку и вызов перевозчика делает консьюмер. Поэтому медленный перевозчик
не тормозит кассу, а заказ, которому не хватило товара, становится
backordered и сам «просыпается» после приёмки.

## Компоненты

```
  checkout / WMS
     │ POST /v1/orders
     ▼
┌────────────────────────────┐  publish allocate   ┌──────────────────────┐
│ Fulfillment API (Node)     │ ──────────────────► │ redis (queue)        │
│ products, batches, orders, │                     │ allocate, pick,      │
│ planner, stats             │ ◄────────────────── │ ship, restock        │
└─────┬──────────┬───────────┘      consume        └──────┬───────────────┘
      │          │                                        │
      │ SQL      │ picklist / label                       │
      ▼          ▼                                        ▼
┌───────────┐  ┌────────────────────┐          ┌────────────────────────┐
│ postgres  │  │ minio (S3)         │          │ allocate (consumer)    │
│ Product   │  │ picks/<order>.json │          │ FEFO по партиям        │
│ Batch     │  │ labels/<order>.txt │          │ reserve / backorder    │
│ SalesOrder│  └────────────────────┘          └──────────┬─────────────┘
│ OrderLine │                                             │ pick
│ Reservation│                              ┌─────────────▼─────────────┐
│ PickList  │                               │ buildPick (consumer)      │
│ Shipment  │                               │ документ сборки в S3      │
│ Replenish.│                               └─────────────┬─────────────┘
│ Movement  │                                             │ ship
└───────────┘                               ┌─────────────▼─────────────┐
      ▲                                     │ shipOrder (consumer)      │
      │                                     │ io.remote Carrier.create  │
      │                                     └───────┬───────────┬───────┘
      │                                             │           │
      │                                  ┌──────────▼─────┐ ┌───▼──────────┐
      │                                  │ carrier :9094  │ │ websocket    │
      │                                  │ mock 3PL       │ │ topic ops    │
      │                                  └────────────────┘ └──────────────┘
      │
      │ receipt → restock (consumer) → allocate для backordered
```

### Компонент → provider

| Компонент | provider | Что делает |
|-----------|----------|------------|
| Состояние (Product, Batch, SalesOrder, OrderLine, Reservation, PickList, Shipment, Replenishment, Movement) | sql → postgres | строки, unique-ключи, count/aggregate |
| Очередь (allocate, pick, ship, restock) | queue → redis | доставка из API в консьюмеры, retry и dead letter |
| Документы сборки и этикетки | blob → s3 (minio) | picks/<orderId>.json, labels/<orderId>.txt |
| Перевозчик (3PL) | endpoint → внешний HTTP | POST /v1/shipments через io.remote |
| Живой фид склада | stream → websocket | топик ops: allocated / backordered / picking / shipped / cancelled / received |
| Идентификаторы | ids → local | id заказов, партий, резерваций |

Пять внешних систем: postgres, redis, minio, перевозчик, websocket. В
docker-compose три контейнера (postgres, redis, minio) и мок перевозчика на
хосте; endpoint переписывает localhost в host.docker.internal (#42),
поэтому спека и smoke не знают про Docker.

## Модель данных

* **Product** — SKU (уникальный), имя, reorderPoint, счётчики onHand и
  reserved; доступно = onHand − reserved.
* **Batch** — принятая партия: код (уникальный), ячейка bin, количество
  qty, остаток remaining, срок годности. Партии одного SKU лежат в разных
  ячейках, FEFO решает срок, а не порядок приёмки.
* **SalesOrder** — заказ: clientRef (ключ идемпотентности, уникальный),
  customer, address, статус new | backordered | allocated | picking |
  shipping | shipped | cancelled, units/allocatedUnits, перевозчик,
  tracking, ключ этикетки.
* **OrderLine** — строка заказа: SKU, количество, сколько уже
  зарезервировано.
* **Reservation** — резерв одной строки на одну партию. Составной
  unique (lineId, batchId) делает повторную доставку сообщения no-op, а не
  вторым резервом.
* **PickList** — индекс документа сборки; unique orderId — один документ
  на заказ.
* **Shipment** — отправление: перевозчик, tracking, ключ этикетки;
  unique orderId.
* **Replenishment** — предложение закупки, unique productId: повторный
  прогон планировщика обновляет строку, а не плодит дубли.
* **Movement** — append-only журнал склада: receipt / reserve / release /
  ship / writeoff.

## Как это работает

1. **Приёмка.** receive проверяет SKU и уникальность кода партии, пишет
   Batch, Movement(receipt), увеличивает Product.onHand, публикует
   restock(productId) и событие в websocket.
2. **Заказ.** createOrder валидирует строки, склеивает одинаковые SKU,
   проверяет каталог (нет SKU → 404), вставляет заказ и строки, публикует
   allocate(orderId). Повтор с тем же clientRef возвращает тот же заказ.
3. **Распределение (allocate).** Для каждой строки партии читаются
   status=open в порядке expiresAt asc; берётся минимум из остатка и
   потребности, создаётся Reservation(held), уменьшается remaining,
   увеличивается Product.reserved, пишется Movement(reserve).
   Полностью обеспеченный заказ → allocated + pick; иначе → backordered
   (без задания на сборку).
4. **Сборка (buildPick).** Пишет picks/<orderId>.json (SKU, партия, ячейка,
   срок, количество), индексирует документ и переводит заказ в picking.
   Повторная доставка находит PickList и ничего не меняет.
5. **Отгрузка.** ship разрешён только из picking, ставит shipping и
   публикует ship(orderId). Консьюмер вызывает перевозчика, кладёт
   этикетку в S3, помечает резервы shipped, уменьшает onHand и reserved,
   пишет Movement(ship). Ошибка перевозчика — исключение: retry 2, затем
   dead letter, заказ остаётся shipping для оператора.
6. **Отмена.** До отгрузки возвращает каждый held-резерв в партию
   (remaining, reserved, Movement(release)); после shipping/shipped — 409.
7. **Планировщик.** POST /v1/planner/run {now} — единственная замена cron
   (#12). Списывает просроченные партии без held-резервов в
   Movement(writeoff), обновляет/создаёт Replenishment для SKU на уровне
   reorderPoint и меньше, и переопубликовывает allocate для backordered.
   Повторный прогон идемпотентен.
8. **Restock (консьюмер).** Приёмка могла закрыть дефицит: находит
   backordered-заказы, где есть эта строка, и публикует allocate; решение
   всё равно принимает allocate по свежим остаткам.

### Инварианты и их слабое место

onHand, reserved и Batch.remaining — счётчики, обновляемые
read-modify-write. В языке нет CAS/атомарного инкремента (#10, #58), поэтому
два параллельных allocate могли бы потерять обновление. В примере все
изменения остатков идут через один консьюмер allocate (очередь сериализует
доставку), а cancel и receive выполняются в HTTP-запросе и могут пересечься
с ним. Для демо это допустимо и названо прямо; для настоящего склада нужен
CAS по версии строки или транзакционный резерв в БД.

## API

| Метод | Путь | Что |
|-------|------|-----|
| POST | /v1/products | создать SKU; дубль — 409, пустой sku/отрицательный reorderPoint — 400 |
| GET | /v1/products | каталог |
| GET | /v1/products/:productId | SKU + партии по сроку |
| POST | /v1/products/:productId/receipts | принять партию (code, qty, expiresAt, bin); дубль кода — 409 |
| GET | /v1/batches?productId=&status= | партии |
| POST | /v1/orders | заказ (clientRef, customer, address, lines[{sku,qty}]); тот же clientRef — тот же заказ |
| GET | /v1/orders?status=&limit= | журнал заказов |
| GET | /v1/orders/:orderId | заказ + строки + резервы + документ + отправления |
| GET | /v1/orders/:orderId/picklist | документ сборки из S3 (key/content/bytes) |
| POST | /v1/orders/:orderId/ship | передать перевозчику, 200; не из picking — 409 |
| GET | /v1/orders/:orderId/label | этикетка из S3 |
| POST | /v1/orders/:orderId/cancel | отменить до отгрузки, 200; иначе 409 |
| POST | /v1/planner/run | прогон планировщика с явным now |
| GET | /v1/replenishments?status=open | предложения закупки |
| GET | /v1/stats | счётчики заказов, остатки, открытые предложения |
| GET | /v1/dead | dead letter по всем четырём топикам |

## Запуск

```bash
cd 052-warehouse-fulfillment
arcod check
arcod build --impl --port 8090
node mocks/carrier.mjs &          # перевозчик на :9094
arcod run --impl --port 8090
./smoke.sh                        # check + build + run + HTTP-проверки
arcod run --down --impl
```

smoke.sh поднимает мок перевозчика, проверяет FEFO (сначала истекающая
партия), документ сборки и этикетку в S3, идемпотентность clientRef, отмену
с возвратом остатков, backorder и разблокировку приёмкой, три попытки и dead
letter при 503 перевозчика, websocket-события, списание просрочки и
предложение закупки, статистику, 400/404/409.

## Опыт использования Arc

Что сработало хорошо:

* unique (lineId, batchId) (составной ключ, #13) — естественная защита от
  двойного резерва при at-least-once доставке; отдельный «lock» не нужен.
* unique productId на Replenishment превращает идемпотентность
  планировщика в декларацию, а не в код.
* order: "expiresAt asc" + where {status} — FEFO читается одним io.find,
  без ручной сортировки.
* Outbox: ship обновляет заказ и публикует в одной транзакции, поэтому
  «статус shipping без сообщения» невозможен.
* Retry и dead letter работают как обещано: три строки в логе
  (attempt 1/3 ... requeued, 3/3 ... moved to dead letter) и запись с
  lastError в /v1/dead.

Чего не хватило:

* **Нет CAS/атомарного счётчика (#10, #58).** Резерв — read-modify-write по
  Batch.remaining и Product.reserved. Один консьюмер это сериализует, но
  отмена и приёмка идут из HTTP; под нагрузкой возможен перепроданный
  остаток. Нужен update ... where version = ? или транзакционный резерв.
* **Нет cron у job (#12).** Планировщик — публичный POST /v1/planner/run;
  внешний runner должен помнить про него.
* **Ответ файлом — это JSON-запись (#53).** GET .../label отдаёт
  {key, content, bytes}, а не text/plain с content-type. Терминал печати
  должен развернуть поле сам.
* **io.blobPut принимает только строку (#48).** Этикетка — текст; PDF от
  перевозчика пришлось бы кодировать base64 (+33% и ручной sha256).
* **TTL-кэш рядом с sql недоступен (#63).** Кэшировать карточки SKU и
  партии нечем: kv-алиас при store: sql отклоняется на check (A094).
* **Dead letter только по топику и молча.** io.queueDead() без аргумента
  читает топик undefined и возвращает пустой список — первая версия
  GET /v1/dead показывала 0 при непустой очереди. Пришлось перечислять
  четыре топика руками (комментарий в #61).
* **Тело job получает объект именованных параметров.** Для
  job shipOrder(input: ShipInput) рантайм передаёт { input: {...} }, а не
  сам объект: чтение body.orderId даёт пустую строку и сообщение тихо
  подтверждается. Здесь параметр заменён на скаляр orderId (перевозчик уже
  в заказе) — так же делают 046 и 051.
* **Имена impl-файлов на macOS нечувствительны к регистру.** Операция
  picklist и job pickList — это один файл; job пришлось переименовать в
  buildPick. A093 ловит коллизии имён функций, но не коллизию файлов.
