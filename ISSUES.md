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
| [#29](https://github.com/chubakur/arcod/issues/29) | postgres: SCRAM client-first без gs2-заголовка `n,,` — сервис не аутентифицируется | 012, `bind store -> postgres` | fixed (проверено 24.11, 4f206dd; SCRAM ок, postgres+queue блокирует #43) | 24.11.2026 |
| [#30](https://github.com/chubakur/arcod/issues/30) | queue: `bind events -> rabbitmq` поднимает брокер, но рантайм его игнорирует | 012, 009 | fixed | 23.11.2026 |
| [#31](https://github.com/chubakur/arcod/issues/31) | sql: `list<string>` в сущности не вставляется в MySQL JSON (3144) | 012, Tech.skills | fixed | 23.11.2026 |
| [#32](https://github.com/chubakur/arcod/issues/32) | docs: `io.remote` возвращает {status, body}, README показывает тело | 012, Router.offer | fixed | 23.11.2026 |
| [#33](https://github.com/chubakur/arcod/issues/33) | mail: провайдер mailpit объявлен, но у capability нет эффектов | 012 | fixed | 23.11.2026 |
| [#46](https://github.com/chubakur/arcod/issues/46) | job: нет отменяемого контекста — выполняющийся внешний вызов не прервать | 037, cancel посреди slow-шага | open | 24.11.2026 |
| [#47](https://github.com/chubakur/arcod/issues/47) | contract: POST всегда 201, нельзя объявить 200 для идемпотентного действия | 037, `POST /v1/runs/:id/cancel` → 201 | open | 24.11.2026 |
| [#34](https://github.com/chubakur/arcod/issues/34) | store: нет агрегата (sum/avg) — деньги в отчёте считаются вычиткой строк и молча занижаются | 013, `impl/stats.mjs` | fixed (проверено 24.11, 411c01d) | 24.11.2026 |
| [#36](https://github.com/chubakur/arcod/issues/36) | sql: параллельные io-вызовы на одном MySQL-соединении обмениваются наборами строк | 014, job transcode + HTTP | fixed (проверено 24.11, 411c01d) | 24.11.2026 |
| [#37](https://github.com/chubakur/arcod/issues/37) | kv: `bind cache -> redis` поднимает контейнер, но io.save/load пишут в SQL `arcod_kv` | 014, первая версия | fixed (проверено 24.11, 411c01d) | 24.11.2026 |
| [#38](https://github.com/chubakur/arcod/issues/38) | impl: операция `request` роняет сервис — `Identifier 'handleRequest' has already been declared` | 015, операция `request` | fixed (проверено 24.11, 411c01d) | 24.11.2026 |
| [#39](https://github.com/chubakur/arcod/issues/39) | impl: файлы склеиваются в один модуль — одинаковое имя функции ломает `build --impl` | 015, `subjectHash` в двух файлах | fixed (проверено 24.11, 411c01d) | 24.11.2026 |
| [#40](https://github.com/chubakur/arcod/issues/40) | Нет способа вызвать операцию по расписанию: cron есть только у workflow | 016, операция `closeDue` | closed как duplicate → #12 | 24.11.2026 |
| [#41](https://github.com/chubakur/arcod/issues/41) | Несколько `service` в одном модуле: `check` чист, но в compose и роутинге только первый | тест Store + Cache | open | 24.11.2026 |
| [#42](https://github.com/chubakur/arcod/issues/42) | endpoint: `localhost` → `host.docker.internal`, fetch выбирает IPv6 и падает | 016, `io.remote` Mailer | open | 24.11.2026 |
| [#43](https://github.com/chubakur/arcod/issues/43) | postgres + queue: outbox-DDL с запятой перед `)` — миграции падают | 036, минимальный pgprobe2 | fixed (проверено 24.11, 9233d2d) | 24.11.2026 |
| [#48](https://github.com/chubakur/arcod/issues/48) | blob: `io.blobPut` принимает только string — бинарные вложения хранятся base64 | 038, вложение письма в S3 | open | 24.11.2026 |
| [#49](https://github.com/chubakur/arcod/issues/49) | queue: dead letter только читается — запись нельзя снять после replay | 038, `replay` + `GET /v1/dead` | open | 24.11.2026 |

| [#44](https://github.com/chubakur/arcod/issues/44) | hash: `bind sig -> local` проходит check, но `io.hash` в рантайме нет — 500 | 017, первая версия спеки с `sig: hash` | open | 24.11.2026 |
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

## Перепроверка 20.11.2026 (перед 013)

Новых закрытых issue нет: #15–#28 закрыты до 16:30 и уже проверены на
`59ed63e` (раздел «перед 012»), после этого ни один issue не закрывался.

Отдельно про окружение: локальный клон `/Users/chubakur/projects/arcod` был
на `5448fc1` (13.11), а `origin/main` — `59ed63e`. На устаревшем коммите
`arcod build --impl` падает на любом `io.fetch` с «body must not use raw
network» — выглядит как регресс #6, но это старая копия. После
`git merge --ff-only origin/main` сборка проходит. Глобальный npm link не
менялся.

Фидбек из 013:

- новый #34 — `store` не умеет sum/avg, деньги в отчёте считаются вычиткой
  строк (`impl/stats.mjs`);
- #11 — комментарий: тела операций делят модуль, `MAX_ATTEMPTS` в двух
  консьюмерах ломает сборку;
- #12 — комментарий: dunning требует отложенных сообщений, иначе три отказа
  проходят за миллисекунды;
- #32 подтверждён: `io.remote` отдаёт `{status, body}`, в `charge` стоит
  защитный `reply.body ?? reply`.

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


## 014-video-platform — перепроверка и новые пробелы (23.11.2026)

Чистое состояние: `git worktree add --detach /tmp/arcod-verify origin/main`,
`f0119d3`; сборка через `node /tmp/arcod-verify/bin/arcod.mjs`; глобальный
npm link не трогался. Перед работой сняты старые контейнеры и `.arcod`.

Перепроверка закрытых:

- **#29** — postgres не аутентифицируется, но уже по-другому: сгенерированный
  сервис падает с `ReferenceError: timingSafeEqual is not defined` в
  `PgConnection.onAuth` (в импорте `node:crypto` метода нет). Issue
  переоткрыт, статус `regressed`.
- **#30** — не воспроизводится: `bind events -> rabbitmq` теперь честно
  валит `check` (`A083`, «no AMQP driver»), тихого memory-fallback нет.
- **#31** — не воспроизводится: `list<string>` в MySQL JSON вставляется
  (`tags: ["x","y"]` в строке).
- **#32** — не воспроизводится: `README_rus.md:476` документирует
  `{status, body}`.
- **#33** — не воспроизводится: `mail`/`mailpit` убраны из таблицы
  провайдеров.
- **#34** — воспроизводится: `io.aggregate` документирован, но в рантайме
  `TypeError: io.aggregate is not a function` (при объявленном
  `store.aggregate`). Issue переоткрыт, статус `regressed`.

Новые пробелы:

- **#36** — параллельные вызовы стора делят одно MySQL-соединение и
  обмениваются наборами строк (`MySqlConnection` с единственным `pending`).
  Пример 014 обходит это одним сообщением на видео и чтением строк вместо
  `count`.
- **#37** — `bind cache -> redis` провижинит контейнер, но `io.save/load`
  пишут в SQL-таблицу `arcod_kv`, `REDIS_URL` не читается; возможность `kv`
  из спеки 014 убрана.

Итог: 014 собран, `smoke.sh` → PASS (mysql + redis queue + minio + вебхук,
2 консьюмера, ретраи, 409 на дубликат).

## 015-gdpr-erasure — перепроверка и новые пробелы

23.11.2026, чистое состояние: `git worktree add --detach /tmp/arcod-verify origin/main`
(arcod `f0119d3`), старые контейнеры и `.arcod` сняты, сборка через
`node /tmp/arcod-verify/bin/arcod.mjs`, глобальный `npm link` не трогался.

Перепроверка закрытых: новых закрытых с прошлой проверки (23.11.2026, 11:55,
commit `baba94a`) нет — все закрытые arcod-issue закрыты 20.11 или раньше и уже
проверены на чистом состоянии.

Новые пробелы:

- **#38** — операция с именем `request` проходит `check` и `build`, но сервис
  падает на старте: генератор выдаёт `handleRequest` и для операции, и для
  рантайма. Обход — переименовать операцию в `show`.
- **#39** — impl-файлы компилируются в одно пространство имён: одинаковое имя
  функции в двух файлах даёт `duplicate top-level name` только на
  `build --impl`. Общий `lib.mjs`/импорты недоступны.

Итог: 015 собран, `smoke.sh` → PASS (mysql + redis queue + minio + внешний
комплаенс-шлюз; каскад по трём таблицам, манифест в S3, два консьюмера, ретрай
на 503 от шлюза, 409 на повторный запрос).

## Перепроверка 24.11.2026 (перед 016)

Закрыты после прошлой проверки: #34, #36, #37, #38, #39 (23.11.2026,
19:08–22:11 UTC). Все пять проверены на чистом состоянии: свежий worktree
`origin/main` (`411c01d`), без `.arcod/build` и старых контейнеров, сборка
`node /tmp/arcod-verify/bin/arcod.mjs`, глобальный `npm link` не тронут.

- **#12 (расписание)** — подтверждён на 016: `job` не принимает расписание,
  `workflow` с `cron` не исполняется, закрытие лота остаётся HTTP-тиком
  `POST /v1/admin/close`. Заведённый было #40 закрыт как дубликат #12.
- **#34 (store.aggregate)** — не воспроизводится: на mysql
  `io.aggregate('Account', { field: 'amountCents', op: 'sum' })` вернул 3000,
  с `where: { status: 'paid' }` — 1000; в отчёте 016 оборот ставок = 5300
  сходится с суммой принятых. Статус `fixed`.
- **#36 (общее MySQL-соединение)** — не воспроизводится: 200 параллельных
  `GET /v1/videos/:id` (`fetch` + `find`) при работающем консьюмере, который
  писал 20 строк на видео, — ни одного чужого `videoId`. Статус `fixed`.
- **#37 (kv → redis)** — не воспроизводится: `bind cache -> redis`,
  `io.save` создал ключ `msg:k:a` в контейнере redis, значение пережило
  `docker restart service`. Статус `fixed`.
- **#38 (операция `request`)** — не воспроизводится: `public op request`
  собирается и отвечает 200/404, `handleRequest` не конфликтует. Статус
  `fixed`.
- **#39 (склейка impl)** — не воспроизводится в заявленном виде: общий модуль
  не появился, но `check` теперь даёт `A093` с файлом, строкой и подсказкой
  до сборки. Это ровно второй вариант из ожидания issue. Статус `fixed`.

Итог: 016-auction собран, `smoke.sh` → PASS (mysql + redis queue + почтовый
шлюз; ставки и три отказа, антиснайпинг +120 с, закрытие sold/unsold,
три письма, агрегат оборота, идемпотентный второй тик, 404).

## Перепроверка 24.11.2026 (перед 036)

Закрыты после прошлой проверки: #40 (24.11, 08:47 UTC) и #29 (23.11, 20:38 —
статус в журнале был `regressed`). Проверка на чистом состоянии: свежий worktree
`origin/main` (`4f206dd`), без `.arcod/build` и старых контейнеров, глобальный
`npm link` не тронут.

- **#40** закрыт владельцем как duplicate #12 (`timers: нет отложенного запуска`).
  #12 остаётся открытым; отдельной проверки не требует.
- **#29 (SCRAM)** — не воспроизводится: минимальный postgres-проект без очереди
  (`bind store -> postgres`, `postgres:16-alpine`) отдаёт `/healthz` 200,
  `POST /v1/notes` 201, `GET /v1/notes/:id` 200, в логе postgres ни одного
  `malformed SCRAM`. Статус `fixed`.
- Побочная находка при той же проверке: **postgres + queue** падает на outbox-DDL
  (`published_at BIGINT NULL,\n\n);`), `src/migrate.ts` кладёт пустую строку в
  join для не-mysql диалекта. Новый **#43**, пример 036 собран на MySQL.

Итог: 036-notification-center собран, тесты на чистом arcod `4f206dd`;
`smoke.sh` → PASS (mysql + redis queue + s3 + почтовый шлюз; шаблон и 409,
кампания на 4 адреса, fan-out и deliver консьюмеры, 3 письма с подстановкой,
третья неудача → dead letter, дневная аналитика 3/1, CSV в S3 и обратно,
идемпотентный второй fan-out, 400 и 404).

## Перепроверка 24.11.2026 (перед 017)

Новых закрытых issue после прошлой проверки нет: последний — #40 (24.11,
08:47 UTC, duplicate #12), он уже был разобран в проверке перед 036. Чистый
worktree `origin/main` (`a6863b8`) поднят только под сборку 017.

Итог: 017-contract-signing собран, `smoke.sh` → PASS (mysql + redis queue + s3 +
почтовый шлюз; конверт → два подписанта по очереди → приглашения и напоминание
письмами → seal-консьюмер → манифест verified → подмена документа ломает
подписи → decline со skipped → статистика и 404).
Новый #44 (hash-capability без рантайма), пример обходит через `crypto.subtle`.

## 037-ci-orchestrator — перепроверка и новые пробелы (24.11.2026)

Перепроверка закрытых: новых закрытых после проверки перед 017 нет (последний —
#40, duplicate #12, проверен 24.11). Отдельный чистый checkout не требовался.

Собран 037: MySQL + Redis-очередь + S3 + внешний раннер (`endpoint`), job
`execute` с retry, логи шагов и артефакты в S3, отмена между шагами, 409 на
параллельный прогон, счётчики, dead letter. `smoke.sh` → PASS (успешный прогон
из 3 шагов, лог и артефакт обратно из S3, 409, отмена, failed+skipped,
1/1/1 в статистике, 404).

Новые пробелы:

- **#46** — job нельзя прервать: отмена видна только перед следующим шагом,
  уже отправленный вызов раннера дорабатывает. Пример обходит кооперативной
  проверкой `cancelRequested`.
- **#47** — POST всегда отвечает 201: у `cancel` нет способа объявить 200.
- **#45** закрыт как дубликат #32 (`io.remote` → `{status, body}`); в комментарий
  добавлен новый факт: забытый `body` даёт `NaN` в SQL и ошибку
  `1054 Unknown column 'NaN'`, диагностика уводит в БД.

## 038-email-to-api — перепроверка и новые пробелы (24.11.2026)

Чистое состояние: worktree `origin/main` = `9233d2d`, без `.arcod`, без
контейнеров. Перепроверен единственный закрытый после прошлой проверки issue
с воспроизведением:

- **#43** (postgres + queue: запятая в outbox-DDL) — **fixed**. Сначала
  минимальный `pgprobe2` (postgres + redis, insert + publish), затем
  `038-email-to-api`: миграции `0001..0007` применились, сервис отвечает,
  строки и очередь работают. Outbox-DDL на postgres собирается без запятой
  перед `)`; на mysql остался прежним. Комментарий в #43, reopen не нужен.
- #40 и #45 закрыты как дубликаты (#12 и #32), воспроизведение не требуется.

Собран 038: Postgres + Redis-очередь + MinIO + почтовый провайдер (endpoint) +
подписчик (endpoint), два job'а: `ingest` (курсор, дедуп, S3, строки) и
`deliver` (HMAC, retry, dead letter). `smoke.sh` → PASS: маршрутизация,
тело и вложение из S3, подпись, дедуп, две неудачи + успех, dead letter,
replay, 409, 404.

Новые пробелы:

- **#48** — `files.put` только текст: вложение кладётся base64 (+33%), размер
  и sha256 считаются вручную.
- **#49** — dead letter нельзя снять: после replay старая запись остаётся,
  `/v1/dead` растёт вечно.
- **#33** подтверждён как fixed: в `origin/main` провайдера `mail` в таблице
  нет; почта в примере — внешний HTTP-провайдер.
- `#39` (impl склеиваются в один модуль) остаётся проектным решением: `A093`
  ловит коллизию имён, обходим префиксами.
