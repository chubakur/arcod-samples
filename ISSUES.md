# Журнал фидбека в arcod

Каждая жалоба/предложение из этого репозитория — issue в
[`chubakur/arcod`](https://github.com/chubakur/arcod/issues). Закрытый issue —
это заявление, а не доказательство: перед новым проектом автоматизация
перепроверяет закрытые на **чистом состоянии** (свежий checkout arcod, без
`.arcod/build` и старых контейнеров) и только потом ставит `fixed`.

| Issue | Что | Воспроизведение | Статус | Проверено |
|-------|-----|-----------------|--------|-----------|
| [#2](https://github.com/chubakur/arcod/issues/2) | `arcod run --down` пересобирает проект, падает без `--impl`, чистит `.arcod/build` | 001, `arcod run --down` | fixed (проверено 19.11, c72e338) | 19.11.2026 |
| [#3](https://github.com/chubakur/arcod/issues/3) | В `examples` нет литерала списка: `W012` не закрыть для `list<T>` | 001, `arcod check` | fixed (проверено 19.11, c72e338) | 19.11.2026 |
| [#4](https://github.com/chubakur/arcod/issues/4) | У подкоманд нет `--help`, неизвестный флаг даёт стектрейс | 001, `arcod run --help` | fixed | 18.11.2026 |
| [#5](https://github.com/chubakur/arcod/issues/5) | Два capability с одним `redis(host)` дают дубликат сервиса в compose | 002, `arcod build --impl` + `docker compose config` | fixed | 18.11.2026 |
| [#6](https://github.com/chubakur/arcod/issues/6) | impl: sandbox запрещает документированный `io.fetch` | 002, `arcod build --impl` | fixed | 18.11.2026 |
| [#7](https://github.com/chubakur/arcod/issues/7) | queue: `io.queueDead()` с redis падает на RESP-массиве | 002, `GET /v1/dead` | fixed | 18.11.2026 |
| [#8](https://github.com/chubakur/arcod/issues/8) | queue: job с одним параметром получает весь объект сообщения | 002, публикация `{eventId}` | fixed | 18.11.2026 |
| [#9](https://github.com/chubakur/arcod/issues/9) | sql: `io.find` падает с `TypeError: q is not a function` | 003, `store: sql` + список | fixed | 19.11.2026 |
| [#10](https://github.com/chubakur/arcod/issues/10) | kv: нет CAS/атомарного счётчика для read-modify-write | 003, параллельные `POST /ops`; 010, остаток `sql`-товара | open | 19.11.2026 (010) |
| [#11](https://github.com/chubakur/arcod/issues/11) | impl: тела операций делят один модуль, top-level имена сталкиваются в рантайме | 004, `const LINES` в `tick` и `replay` | fixed | 19.11.2026 |
| [#12](https://github.com/chubakur/arcod/issues/12) | timers: нет отложенного запуска at/after, дедлайн нельзя закрыть без запроса | 004, `settle` на каждом `tick` | open | — |
| [#13](https://github.com/chubakur/arcod/issues/13) | rules: `unique` не поддерживает составной ключ — модель хранит синтетическое поле | 005, `arcod check` на `unique F.(name, fence)` | fixed | 19.11.2026 |
| [#14](https://github.com/chubakur/arcod/issues/14) | http: ошибка не может вернуть данные — в 409 нет fence и `expiresAt` | 005, `POST /v1/locks/:name/acquire` | fixed | 19.11.2026 |
| [#15](https://github.com/chubakur/arcod/issues/15) | store: нет count/агрегата — счётчики индекса считаются полным сканом | 006, `GET /v1/stats` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#16](https://github.com/chubakur/arcod/issues/16) | examples: элемент списка не читается — `hits[0]` даёт `unsupported call expression` | 006, `arcod test --impl` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#17](https://github.com/chubakur/arcod/issues/17) | test: второй path-параметр сдвигает аргументы тела — примеры получают чужие значения | 007, `arcod test --impl` на route с двумя `:param` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#18](https://github.com/chubakur/arcod/issues/18) | llm: нет `embed` — векторному хранилищу нечем считать эмбеддинги | 007, `text`-запрос без llm | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#19](https://github.com/chubakur/arcod/issues/19) | store: `insert` без `id` даёт 400 `Invalid` без указания поля, `check` молчит | 007, коллекция с натуральным ключом; подтверждено на 008 (`Claim`) | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#20](https://github.com/chubakur/arcod/issues/20) | store: `find` умеет только равенство — таймеры и очереди сканируют всю сущность | 008, выбор должных запусков по `nextAt` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#21](https://github.com/chubakur/arcod/issues/21) | impl: неизвестное имя сущности в `io.*` даёт 500 `Internal` без имени и стектрейса | 008, `'Workflow'` вместо `WorkflowRec` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#22](https://github.com/chubakur/arcod/issues/22) | sql: `io.find` падает — `const q` перекрывает `q(name)` в `entityFind` | 009, `GET /v1/reports` (list); 010, `io.find('Product')` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#23](https://github.com/chubakur/arcod/issues/23) | sandbox: `io.fetch(...)` ловится как raw network | 009, `arcod build --impl` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#24](https://github.com/chubakur/arcod/issues/24) | sql: `bind store -> postgres` генерирует MySQL-клиент, `/healthz` зависает | 009, bind postgres | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#26](https://github.com/chubakur/arcod/issues/26) | olap: `uses x: olap` + `x.insert` проходят check, clickhouse поднимается, но эффектов и адаптера нет | 011, `main.arc` без olap; минимальный спек в issue | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#27](https://github.com/chubakur/arcod/issues/27) | emit: DTO-типы становятся таблицами; `id: string` в ответе даёт `PRIMARY KEY (TEXT)` и MySQL 1170 | 011, `AlertAck { id: string }` → миграция alertack | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#28](https://github.com/chubakur/arcod/issues/28) | jobs: тело с одним параметром получает `{param}`, пример 009 ждёт значение — задание теряется молча | 011, `rollup` без защитного разбора; 009 `process` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#25](https://github.com/chubakur/arcod/issues/25) | `build --impl` не пересобирает docker-образ: `compose up` поднимает старый impl | 010, правка `impl` + `compose up` | fixed (проверено 20.11, 59ed63e) | 20.11.2026 |
| [#29](https://github.com/chubakur/arcod/issues/29) | postgres: SCRAM client-first без gs2-заголовка `n,,` — сервис не аутентифицируется | 012, `bind store -> postgres` | open | 20.11.2026 |
| [#30](https://github.com/chubakur/arcod/issues/30) | queue: `bind events -> rabbitmq` поднимает брокер, но рантайм его игнорирует | 012, 009 | open | 20.11.2026 |
| [#31](https://github.com/chubakur/arcod/issues/31) | sql: `list<string>` в сущности не вставляется в MySQL JSON (3144) | 012, Tech.skills | open | 20.11.2026 |
| [#32](https://github.com/chubakur/arcod/issues/32) | docs: `io.remote` возвращает {status, body}, README показывает тело | 012, Router.offer | open | 20.11.2026 |
| [#33](https://github.com/chubakur/arcod/issues/33) | mail: провайдер mailpit объявлен, но у capability нет эффектов | 012 | open | 20.11.2026 |

## Перепроверка 19.11.2026 (перед 006)

Закрыты после прошлой проверки: #11, #13, #14 (18.11.2026, 16:34–16:44).
Все три проверены на чистом состоянии (19.11.2026, `c72e338`): свежий
worktree, удалённые контейнеры и `.arcod`, сборка через
`node /tmp/arcod-verify/bin/arcod.mjs`. Ни один не воспроизвёлся — комментарии
с выводом в issue, статус `fixed`.

* #11 — сборка отказывает: `duplicate top-level name "LINES" in impl/replay.mjs and impl/tick.mjs`.
* #13 — `unique Fence.(name, fence)`: вторая пара даёт 409, другое число при том же имени — 201.
* #14 — 409 несёт объявленные поля: `{"error":"Conflict","fence":7,"expiresAt":...}`.

Новые пробелы из 006: #15 (нет count/агрегата) и #16 (в примерах нельзя
прочитать `hits[0]`).

## Перепроверка 18.11.2026 (перед 005)

Закрытых **после** прошлой проверки (18.11.2026, 10:46) нет: #2–#8 закрыты в
07:41–07:42 и уже проверены на чистом состоянии; arcod на `origin/main` с тех
пор не менялся (`8c7c257`). Дополнительно: #3 (литерал списка) подтверждён
новым примером — `acquireAll(["orders/2","orders/1"])` в `examples` парсится и
исполняется, `arcod check` чист, `arcod test` — 5/5.

## Перепроверка 19.11.2026 (перед 007)

Новых закрытых после проверки перед 006 нет. Расхождение в журнале: #9 был
закрыт 18.11 16:32, но стоял `open` — проверен отдельно на чистом состоянии
(19.11.2026, `c72e338`): `arcod build --impl` для `examples/tasks-sql`,
запуск на MySQL 8.4, `POST /v1/tasks` ×2 и `GET /v1/tasks?sort=title` → 200,
порядок `a-task` перед `b-task`, `TypeError: q is not a function` нет.
Комментарий в issue, статус `fixed`.

Новые issue из 007: #17 (аргументы примера при двух path-параметрах),
#18 (`llm.embed`), #19 (`insert` без `id` — тихий 400).

## Перепроверка 19.11.2026 (перед 008)

Закрытых после прошлой проверки нет: #9, #11, #13, #14 закрыты 18.11 и уже
проверены; новых закрытий с тех пор не появилось. Проверка не запускалась —
нечего открывать заново.

Новые issue из 008: #20 (`find` без диапазонов — план по `nextAt` невозможен),
#21 (неизвестная сущность в `io.*` — 500 без диагностики). К #19 добавлен
комментарий с воспроизведением на `Claim` без `id`.

## Проверка 19.11.2026 (перед 010)

Закрытых после прошлой проверки нет: все закрытые (#2–#9, #11, #13, #14) закрыты
18.11.2026, последняя проверка — 19.11.2026 на `c72e338`. Новые наблюдения
добавлены комментариями в #10 и #22; создан #25. Пример 010 — PASS.

## Как проверяем

1. `gh issue list -R chubakur/arcod --state all` — ищем закрытые с прошлой проверки.
2. Свежий checkout: `git worktree add --detach /tmp/arcod-verify origin/main`.
3. В примере: остановить и удалить контейнеры, удалить `.arcod`, собрать заново
   через `node /tmp/arcod-verify/bin/arcod.mjs ...` (глобальный `npm link` не трогаем).
4. Повторить шаги из issue.
5. Воспроизвелось → комментарий с выводом и `gh issue reopen`, статус `regressed`.
   Не воспроизвелось → комментарий «проверено на чистом состоянии», статус `fixed`.

## Перепроверка 20.11.2026 (перед 012)

Закрыты после прошлой проверки: #15–#28 (19.11.2026, 16:32–18:30).
Все проверены на чистом состоянии (worktree на `origin/main`, commit
`59ed63e`, без `.arcod` и старых контейнеров, сборка через
`node /tmp/arcod-verify/bin/arcod.mjs`):

- #15, #16, #17, #18, #19, #20, #21, #22, #23, #25, #26, #27, #28 — не
  воспроизводятся, комментарий в issue, статус `fixed`.
- #24 — исходный симптом (MySQL-клиент вместо postgres, зависание
  `/healthz`) ушёл, но postgres не аутентифицируется по SCRAM → новый #29.
- Новые: #29 (postgres SCRAM), #30 (rabbitmq игнорируется),
  #31 (`list<string>` в MySQL JSON), #32 (`io.remote` возвращает конверт),
  #33 (mail-провайдер без эффектов).

