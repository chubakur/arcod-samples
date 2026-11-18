# Журнал фидбека в arcod

Каждая жалоба/предложение из этого репозитория — issue в
[`chubakur/arcod`](https://github.com/chubakur/arcod/issues). Закрытый issue —
это заявление, а не доказательство: перед новым проектом автоматизация
перепроверяет закрытые на **чистом состоянии** (свежий checkout arcod, без
`.arcod/build` и старых контейнеров) и только потом ставит `fixed`.

| Issue | Что | Воспроизведение | Статус | Проверено |
|-------|-----|-----------------|--------|-----------|
| [#2](https://github.com/chubakur/arcod/issues/2) | `arcod run --down` пересобирает проект, падает без `--impl`, чистит `.arcod/build` | 001, `arcod run --down` | fixed | 18.11.2026 |
| [#3](https://github.com/chubakur/arcod/issues/3) | В `examples` нет литерала списка: `W012` не закрыть для `list<T>` | 001, `arcod check` | fixed | 18.11.2026 |
| [#4](https://github.com/chubakur/arcod/issues/4) | У подкоманд нет `--help`, неизвестный флаг даёт стектрейс | 001, `arcod run --help` | fixed | 18.11.2026 |
| [#5](https://github.com/chubakur/arcod/issues/5) | Два capability с одним `redis(host)` дают дубликат сервиса в compose | 002, `arcod build --impl` + `docker compose config` | fixed | 18.11.2026 |
| [#6](https://github.com/chubakur/arcod/issues/6) | impl: sandbox запрещает документированный `io.fetch` | 002, `arcod build --impl` | fixed | 18.11.2026 |
| [#7](https://github.com/chubakur/arcod/issues/7) | queue: `io.queueDead()` с redis падает на RESP-массиве | 002, `GET /v1/dead` | fixed | 18.11.2026 |
| [#8](https://github.com/chubakur/arcod/issues/8) | queue: job с одним параметром получает весь объект сообщения | 002, публикация `{eventId}` | fixed | 18.11.2026 |
| [#9](https://github.com/chubakur/arcod/issues/9) | sql: `io.find` падает с `TypeError: q is not a function` | 003, `store: sql` + список | open | — |
| [#10](https://github.com/chubakur/arcod/issues/10) | kv: нет CAS/атомарного счётчика для read-modify-write | 003, параллельные `POST /ops` | open | — |
| [#11](https://github.com/chubakur/arcod/issues/11) | impl: тела операций делят один модуль, top-level имена сталкиваются в рантайме | 004, `const LINES` в `tick` и `replay` | open | — |
| [#12](https://github.com/chubakur/arcod/issues/12) | timers: нет отложенного запуска at/after, дедлайн нельзя закрыть без запроса | 004, `settle` на каждом `tick` | open | — |

## Как проверяем

1. `gh issue list -R chubakur/arcod --state all` — ищем закрытые с прошлой проверки.
2. Свежий checkout: `git worktree add --detach /tmp/arcod-verify origin/main`.
3. В примере: остановить и удалить контейнеры, удалить `.arcod`, собрать заново
   через `node /tmp/arcod-verify/bin/arcod.mjs ...` (глобальный `npm link` не трогаем).
4. Повторить шаги из issue.
5. Воспроизвелось → комментарий с выводом и `gh issue reopen`, статус `regressed`.
   Не воспроизвелось → комментарий «проверено на чистом состоянии», статус `fixed`.
