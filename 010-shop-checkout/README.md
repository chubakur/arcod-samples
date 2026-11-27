# 010 — Shop Checkout

Магазин с оплатой через внешний платёжный шлюз. Каталог и заказы живут в MySQL,
счёт-фактура — в S3, задание на упаковку — в RabbitMQ, деньги авторизует чужой
сервис по HTTP. Четыре интеграции, фоновый консьюмер и внешний вызов в одном
сервисе — не «сервис + kv».

## Стек

| Компонент | Роль | Provider |
|-----------|------|----------|
| `Shop` | HTTP API + consumer очереди | — |
| `db` | товары и заказы | `mysql` |
| `queue` | очередь заданий на упаковку | `redis` |
| `s3` | счёт-фактура заказа | `s3` (MinIO) |
| `Gateway` | авторизация платежа | `endpoint` (внешний сервис, `mock/gateway.mjs`) |

```
POST /v1/orders ──▶ mysql: Product (stock -= qty)
                 ├─▶ Gateway POST /v1/charges ── approved?
                 ├─▶ mysql: Order status=paid|rejected
                 └─▶ outbox ──▶ redis pack ──▶ consumer:
                                                   s3.put invoice
                                                   mysql: Order status=packed
```

Шлюз — «чужой» сервис: в спеке это `external service Gateway`, контейнер для него
не генерируется. Локально его играет `mock/gateway.mjs`, адрес приходит из
`bind Gateway -> endpoint(url: ...)`; для docker `localhost` переписывается в
`host.docker.internal`.

## API

| Метод | Путь | Что делает |
|-------|------|------------|
| POST | `/v1/products` | создать товар; `sku` уникален; цена в копейках |
| GET | `/v1/products/:id` | товар и остаток |
| POST | `/v1/orders` | проверить остаток, авторизовать платёж, поставить в очередь |
| GET | `/v1/orders/:id` | статус: `paid`, `rejected`, `packed` |
| GET | `/v1/orders/:id/invoice` | счёт из S3; до упаковки — `409` |

Статусы: оплата отклонена → заказ сохраняется как `rejected`, остаток не
меняется, задания в очереди нет. Успешная оплата → `paid` → consumer → `packed`.

## Запуск

```bash
node mock/gateway.mjs &                 # платёжный шлюз на :9099
arcod check
arcod build --impl --port 8095
docker compose -f .arcod/build/docker-compose.yml build
docker compose -f .arcod/build/docker-compose.yml up -d
./smoke.sh                               # полный прогон, PASS в конце
```

Остановка: `docker compose -f .arcod/build/docker-compose.yml down -v`.
`smoke.sh` сам поднимает mock, пересобирает образ и убирает контейнеры.

## Опыт использования Arc

Что сработало:

- `external service` + `bind Gateway -> endpoint(url:)` — рабочий способ описать
  чужой HTTP-сервис; в compose появляется `GATEWAY_URL`, localhost переписан на
  `host.docker.internal`, вызов из operation дошёл до mock без правок.
- `rules { unique Product.sku }` реально работает: повторный `insert` бросает
  `ArcodError('Conflict')`, и impl может вернуть объявленную ошибку, а не 500.
- Outbox + `queue.publish` + `job` дают at-least-once доставку: после оплаты
  консьюмер сам пишет счёт в S3 и меняет статус.

Чего не хватило:

- `io.find` со `sql` не работает: сгенерированный `entityFind` объявляет
  `const q = query` и затеняет хелпер `q(name)` — `TypeError: q is not a
  function`. Поэтому листинг каталога (`GET /v1/products`) из API убран;
  дубликат `sku` ловится по `ArcodError('Conflict')` от `insert` (issue #22).
- Нет условного обновления (compare-and-set): остаток списывается
  read-modify-write, два параллельных заказа могут уйти в минус (issue #10).
- `arcod build --impl` перегенерирует файлы, но не пересобирает docker-образ;
  `docker compose up` молча поднимает старый код, пока не сделаешь
  `docker compose build` (issue #25).
- Листинг с курсором/сортировкой без `find` нечем выразить; после починки #22
  `GET /v1/products` возвращается одной строкой в impl и спеке.

## Проверки

`./smoke.sh` проверяет: health, создание товара, уникальность sku (409),
авторизацию платежа (3750), упаковку консьюмером, счёт из S3, списание остатка
(10 → 7), отказ шлюза без списания и без счёта (409), oversell (409), плохое
количество (400), неизвестный заказ (404). В конце печатает `sample 010: PASS`.
