# 004 — Turn clock

Сервер пошаговых партий, где время — полноценный участник: у каждого игрока
банк времени, ход стоит столько, сколько думал, просрочил — ход уходит
сопернику, банк кончился — партия проиграна.

Это backend-пример: доска, часы, журнал событий и websocket-рассылка. UI нет.
Игра выбрана простой (крестики-нолики на 3×3), чтобы вся сложность была в
часах, а не в правилах.

## Зачем

Обычный CRUD проверяет формы запросов. Здесь проверяется другое:

1. **Таймаут — это факт, а не запрос.** Просроченный дедлайн материализуется в
   событие с `at = deadline`, даже если клиент пришёл позже. Два наблюдателя,
   опросившие комнату в разное время, получают одинаковый лог.
2. **Переподключение без потерь.** Клиент присылает `sinceSeq` и получает
   только новые события + актуальное состояние.
3. **Повтор хода не двигает доску.** `moveId` — ключ идемпотентности: повтор
   после потерянного ответа возвращает `duplicate: true` и не списывает время.
4. **Гонка за один ход.** Два одновременных хода одного игрока: ровно один
   принят, второй — `out-of-turn`.

## Модель

```arcod
type Room = {
  id: RoomId, code: string, name: string,
  status: string,          // waiting | active | finished
  board: string,           // 9 символов: '.', 'x' (p1), 'o' (p2)
  p1: Player, p2: Player?,
  turn: string,            // 'p1' | 'p2' | ''
  seq: int,                // последний номер события
  turnMs: int, bankMs: int,
  turnStartedAt: datetime?, deadline: datetime?,
  winner: string?, reason: string?
}
```

- **Player** — имя, банк в миллисекундах, число таймаутов и ходов.
- **Seat** — токен (id записи), комната и роль. Живёт отдельно от `Room`,
  поэтому чтение комнаты не выдаёт чужое право на ход.
- **Event** — `start | move | timeout | resign`, с `seq`, `cell`, `moveId`,
  `at`. `seq` — курсор для переподключения.

### Часы

1. Старт: `deadline = now + min(turnMs, bank)` первого игрока.
2. Ход: банк уменьшается на реальное время раздумья
   (`now - turnStartedAt`), ход пишется в лог, очередь переходит,
   `deadline = now + min(turnMs, bank)` следующего.
3. Любой `tick` сначала вызывает `settle`: пока `now >= deadline`, пишется
   событие `timeout` с `at = deadline`, банк уменьшается на выданный грант,
   очередь переходит. Когда банк становится нулём — `finished`, `reason: timeout`.
4. Ход, пришедший после своего дедлайна, не «отклоняется»: ход уже перешёл,
   поэтому ответ `accepted: false, note: "out-of-turn"`. Это честнее, чем
   принимать ход задним числом.

### Проекция

`GET /v1/rooms/:id/replay` заново складывает `move`-события в доску и сравнивает
с сохранённой. `consistent: false` означал бы, что лог и снапшот разошлись.

## API

| Метод | Путь | Операция | Что делает |
|-------|------|----------|-----------|
| POST | `/v1/rooms` | `createRoom` | комната, код входа, токен первого игрока |
| POST | `/v1/rooms/:roomId/join` | `join` | вход по коду; полная комната → зритель |
| POST | `/v1/rooms/:roomId/tick` | `tick` | `kind: sync | move | resign`, дельта событий |
| GET | `/v1/rooms/:roomId/events` | `events` | журнал: `after`, `limit` |
| GET | `/v1/rooms/:roomId/replay` | `replay` | проекция по журналу |
| GET | `/v1/rooms` | `listRooms` | последние комнаты |

`tick` возвращает:

```json
{
  "seq": 4, "accepted": true, "duplicate": false, "timeouts": 0,
  "note": "", "room": { "...": "..." },
  "events": [ { "seq": 3, "kind": "move", "cell": 0 } ],
  "serverTime": "2026-11-18T11:45:00.000Z"
}
```

### Пример

```bash
R=$(curl -sS -X POST localhost:8097/v1/rooms \
  -H 'content-type: application/json' \
  -d '{"name":"duel","player":"alice","turnSeconds":30,"bankSeconds":120}')
ID=$(echo "$R" | jq -r .room.id)
CODE=$(echo "$R" | jq -r .room.code)
TOKEN=$(echo "$R" | jq -r .token)

curl -sS -X POST "localhost:8097/v1/rooms/$ID/join" \
  -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"name\":\"bob\"}"

curl -sS -X POST "localhost:8097/v1/rooms/$ID/tick" \
  -H 'content-type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"kind\":\"move\",\"cell\":4,\"moveId\":\"5c1c9f1e-0000-4000-8000-000000000001\"}"
```

## Запуск

```bash
node /path/to/arcod/bin/arcod.mjs check
node /path/to/arcod/bin/arcod.mjs build --impl
node /path/to/arcod/bin/arcod.mjs run --impl --port 8097
ARCOD=/path/to/arcod/bin/arcod.mjs ./smoke.sh
node /path/to/arcod/bin/arcod.mjs run --down --impl
```

`smoke.sh` по умолчанию зовёт `arcod` из PATH; `ARCOD=...` переопределяет
бинарь (удобно для свежего checkout без `npm link`).

## Что проверяет smoke

1. Комната создаётся в статусе `waiting`, доска пустая, последовательность 0.
2. Второй игрок входит по коду, партия стартует, `turn = p1`.
3. Ход в центр: `accepted`, доска `....x....`, очередь у `p2`.
4. Повтор того же `moveId` с другой клеткой: `duplicate: true`, доска и `seq` не изменились.
5. Ход не в свою очередь → `accepted: false, note: out-of-turn` (HTTP 200, не ошибка).
6. Занятая клетка → `note: cell-taken`.
7. `events?after=3` возвращает ровно одно событие.
8. `replay` складывает три хода в ту же доску, `consistent: true`.
9. Websocket получает `resign` в момент, когда он случился.
10. После `finished` ход отклоняется с `note: finished`, поздний вход — `spectator`.
11. Два одновременных хода: принят ровно один, `seq` = 2, на доске один `x`.
12. Банк 4 с / 2 с на ход: первый дедлайн двигает очередь, затем банк кончается —
    `finished`, `winner: p2`, `reason: timeout`; в журнале три `timeout`,
    ни одного клиентского запроса.

## Опыт использования Arc

Что легло хорошо:

- `datetime` + `seq` + список событий хватило, чтобы описать и часы, и
  переподключение без единого «технического» поля.
- Разделение `Room` / `Seat` получилось естественным: токен — это id записи,
  `io.fetch('Seat', token)` и есть проверка права.
- `effects` дисциплинируют: видно, что `tick` пишет три типа записей и
  публикует в поток, а `replay` — только читает.
- Пример в `examples` (`arcod test`) проходит на in-memory kv без Docker.

Чего не хватило (issue в `chubakur/arcod`):

- **Тела операций — один модуль.** `const LINES` в `tick.mjs` и `replay.mjs`
  роняет контейнер на старте: `SyntaxError: Identifier 'LINES' has already been
  declared`. `check` и `build` при этом чистые. Пришлось неймспейсить вручную
  (`TICK_LINES`, `REPLAY_LINES`) и дублировать движок — импорты запрещены.
  → [#11](https://github.com/chubakur/arcod/issues/11)
- **Нет отложенного запуска.** Часы нельзя закрыть событием «через N секунд»:
  job умеет только cron/event/manual/after, workflow не исполняется (`W022`).
  Таймауты материализуются на первом же запросе — это записано в правилах выше
  как осознанное решение, но инвариант «событие наступает само» недостижим.
  → [#12](https://github.com/chubakur/arcod/issues/12)
- **Нет CAS в kv.** Два тика одной комнаты — это read-modify-write. В примере
  они сериализуются локом в процессе; второй инстанс потеряет ход.
  → [#10](https://github.com/chubakur/arcod/issues/10) (открыт)
- **Нет перечислений.** `status`, `kind`, `role` — строки: опечатка в impl
  ловится только тестом. Хочется `enum`/`union`, чтобы `check` ругался.

## Ограничения примера

- лок на комнату живёт в процессе: один контейнер — да, горизонтальное
  масштабирование — нет (см. #10);
- идемпотентность ищет `moveId` через `find` по полю, а это скан: для партии
  на 9 клеток нормально, для потока событий — нужен индекс;
- часы «идут» только при обращении к сервису (см. #12);
- зритель получает состояние только через `tick kind=sync`, отдельного
  read-only эндпоинта нет — намеренно, чтобы любой читатель тоже двигал часы.
