# 001 — Expense Splitter

Небольшой backend для совместных трат: группа людей, расходы и итоговые балансы.
Типичный «кто кому сколько должен» после поездки или вечеринки.

## Что умеет

- `POST /v1/groups` — создать группу: имя, список участников, валюта (ISO-4217).
- `POST /v1/groups/:groupId/expenses` — добавить расход: кто заплатил, сколько
  (в минимальных единицах валюты), между кем делится, необязательная заметка.
- `GET /v1/groups/:groupId/ledger` — группа, все расходы и балансы по участникам:
  `paid`, `owed`, `net`.

Сумма делится нацело; остаток от деления раздаётся первым участникам, поэтому
сумма всех `net` всегда равна нулю.

## Модель

- capability `kv` поверх Redis: одна запись `g:<groupId>` на группу.
- capability `ids` — UUID для групп и расходов.
- Валидация: 2+ участника, без дублей, валюта из трёх букв, положительная целая
  сумма, плательщик и участники — члены группы. Нарушения → `400 Invalid`,
  неизвестная группа → `404 NotFound`.

## Запуск

```bash
arcod check
arcod build --impl
arcod run --impl --port 8091   # http://localhost:8091/healthz
./smoke.sh                     # полный прогон с проверками
```

Остановка: `arcod run --down --impl` (без `--impl` команда падает — см. фидбек).

## Пример

```bash
GID=$(curl -sS -X POST localhost:8091/v1/groups -H 'content-type: application/json' \
  -d '{"name":"Trip","members":["ann","bob","cid"],"currency":"EUR"}' | jq -r .id)

curl -sS -X POST localhost:8091/v1/groups/$GID/expenses -H 'content-type: application/json' \
  -d '{"payer":"ann","amount":1000,"participants":["ann","bob","cid"],"note":"dinner"}'

curl -sS localhost:8091/v1/groups/$GID/ledger
```

## Опыт использования Arc

- Модель читается и пишется быстро; типы и эффекты пришлось указать явно, и это
  помогло поймать лишние обращения к хранилищу.
- Ограничение: в `examples` нельзя записать список-литерал, поэтому все
  операции с `list<string>` остались без примеров → предупреждения `W012`.
- `arcod run --down` без `--impl` пытается пересобрать проект и падает на
  reference-эмиттере; подробности — в issue к `chubakur/arcod`.
