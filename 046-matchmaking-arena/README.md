# 046 — Matchmaking arena (2v2, рейтинг, ready-check, Elo)

Очередь на матч 2×2: четыре одиночных игрока встают в очередь, фоновый
консьюмер подбирает состав по рейтингу, матч проходит ready-check, результат
считает Elo, а неизменяемый снимок матча уезжает в S3. Таймаут готовности
возвращает всех четверых в очередь.

Статус: **done** — весь поток собран и проверен, включая websocket и S3.

## Компоненты

```
POST /v1/queue ──▶ mysql: QueueTicket + QueueLock (unique playerId)
      │                 │
      │                 └─▶ redis: matchmake ──▶ consumer 1:
      │                                          guard row → 4 waiting
      │                                          → ArenaMatch(ready) + members
      ▼
GET /v1/matches/:id ◀── ready-check (4/4) ──▶ live ──▶ result
                                                    │
                            ┌───────────────────────┼──────────────────┐
                            ▼                       ▼                  ▼
                    mysql: Elo, wins/losses   websocket: match:<id>  redis: archive
                                                                        │
                                                              consumer 2: S3 snapshot
```

| Компонент | Роль | Provider |
|-----------|------|----------|
| `Arena` | HTTP API, консьюмеры `matchmake` и `archive` | — |
| `db` | игроки, заявки, матчи, составы, lock-строки | `mysql` |
| `redis` | очереди `matchmake`/`archive`, fanout websocket между репликами | `queue` (+ stream transport) |
| `s3` | снимки завершённых матчей | `s3` (MinIO) |
| `live` | события матча клиентам | `stream` (websocket) |

Внешних систем в `docker-compose`: три — MySQL, Redis, MinIO; websocket —
внешний транспорт, а не контейнер.

## Модель

| Сущность | Ключевое |
|----------|----------|
| `ArenaPlayer` | рейтинг, wins/losses/games |
| `QueueTicket` | одна попытка очереди; статусы `waiting/matched/cancelled` |
| `QueueLock` | `unique playerId` — атомарный запрет второй waiting-заявки |
| `ArenaMatch` | `ready → live → finished` либо `cancelled` |
| `ArenaMember` | `unique (matchId, playerId)`, `ratingBefore/After`, `delta` |
| `MatchOutcome` | `unique matchId` — защита от двойного расчёта Elo |
| `MatchGuard` | строка-замок матчмейкера с `expiresAt` (30 с) |

**Подбор.** Консьюмер берёт самую старую waiting-заявку как якорь и добирает
игроков в окне ±400 рейтинга. Четвёрка сортируется и делится «змейкой»
(1+4 против 2+3), поэтому средние команд почти равны. Один проход создаёт не
больше одного матча; глобальная строка `MatchGuard` сериализует проходы
консьюмера и cron-скана.

**Ready-check.** `readyBy = createdAt + 60s`. Все четверо должны ответить;
после четвёртого матч становится `live`. `POST /v1/sweep` с внешним временем
отменяет просроченные лобби и создаёт новые waiting-заявки — это cron-хук, в
примере его дёргает smoke.

**Elo.** Средние рейтинги команд, `K=32`, ожидание по логистической кривой;
дельты зеркальные (±delta), сумма по матчу всегда 0. Победитель получает
`+delta`, проигравший `-delta`.

**Архив.** После результата операция публикует `archive`; консьюмер пишет
`matches/<id>.json` в S3 и проставляет `archiveKey`. Повторная доставка видит
ключ и не создаёт второй объект.

## API

| Метод | Путь | Что делает |
|-------|------|------------|
| POST | `/v1/players` | создать игрока (rating 0..4000, по умолчанию 1200) |
| GET | `/v1/players/:id` | профиль |
| GET | `/v1/leaderboard?limit=` | топ по рейтингу |
| POST | `/v1/queue` | встать в очередь; 409 при активной заявке |
| GET | `/v1/queue/:playerId` | последняя заявка и её матч |
| POST | `/v1/queue/:playerId/cancel` | снять waiting-заявку |
| POST | `/v1/match/scan` | cron-скан и восстановление после падения |
| GET | `/v1/matches/:id` | матч + состав |
| POST | `/v1/matches/:id/ready` | ready-check одним игроком |
| POST | `/v1/matches/:id/result` | результат, Elo, архив |
| POST | `/v1/matches/:id/cancel` | отмена; ready-состав возвращается в очередь |
| POST | `/v1/sweep` | отменить лобби с истёкшим `readyBy` |
| GET | `/v1/matches/:id/archive` | снимок из S3 |
| GET | `/v1/stats` | счётчики |
| GET | `/v1/dead` | dead-letter обеих очередей |

Websocket: `ws://localhost:8098/ws?topic=match:<id>`; события `created`,
`ready`, `live`, `finished`, `cancelled`.

## Запуск

```bash
cd 046-matchmaking-arena
arcod check
arcod build --impl --port 8098
arcod run --impl --port 8098
# в другом терминале:
./smoke.sh
```

Остановка: `arcod run --down --impl` или
`docker compose -f .arcod/build/docker-compose.yml down -v`.

`smoke.sh` проверяет: 400 на рейтинг >4000, 404 на незнакомого игрока,
четыре заявки и 409 на дубль, подбор консьюмером и баланс команд, ready-check
3/4 → live, событие `finished` по websocket, нулевую сумму Elo, 409 на
повторный результат, снимок в S3, sweep с возвратом четырёх игроков и пустой
dead-letter. В конце — `PASS`.

## Опыт использования Arc

**Что хорошо.** Модель «типы + `contract` + `effects`» честно описывает
систему: `unique` на составных ключах дал защиту от дублей без ручного SQL, а
`job { on: events.matchmake }` позволил оставить очереди и ретраи рантайму.
`live.publish` и `files.put/get` работают из тела без выбора библиотеки;
websocket-подписка на `match:<id>` совпала с публикацией без прослоек.

**Что пришлось обходить.** В kv нет set-if-absent: `io.takeIf` — это
разрушающее «забрать сообщение», а не `SETNX`, поэтому атомарный lock
пришлось строить строкой `QueueLock` с `unique playerId` (issue #10). Для
замка матчмейкера — такая же строка `MatchGuard` с `expiresAt`: TTL у
таблицы нет, «протухший» lock забирает следующий проход. Отложенных сообщений
нет, поэтому таймаут ready-check — отдельный `sweep(now)`, который в
production дёргает внешний cron. Имя метода для `events.dead` оказалось
`io.queueDead`, а не `io.dead` — на этом первый вариант `GET /v1/dead`
отдавал 500 (issue #61).

**Чего не хватило**

- `kv`: атомарного `setIfAbsent`/CAS — #10 (комментарий с этим примером).
- `impl`: предсказуемого имени `io.dead` для эффекта `events.dead` — #61.
- `queue`: отложенной доставки (`delay`) — таймауты вынесены в `sweep`.
- `contract`: POST всегда отвечает 201, даже когда действие идемпотентно
  (ready/result) — #56, не блокирует пример.
- `sql`: `update` без предусловия (#58); здесь не понадобился, потому что
  расчёт защищён `unique MatchOutcome.matchId`.

## Ограничения примера

- Только соло-очередь 2×2; пати и другие режимы не поддержаны.
- Один сервис; горизонтальное масштабирование консьюмеров проверено логикой
  guard-строки, но не нагрузкой.
- Рейтинг не decay-ится, сезоны и санкции не моделируются.
- Аутентификации нет: `playerId` приходит в теле, как в остальных примерах.
