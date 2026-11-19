# arcod-samples

Песочница для языка [Arcod](https://github.com/chubakur/arcod): каждый каталог —
отдельный небольшой backend-проект, описанный одним `.arc`-файлом и реализацией
операций в `impl/*.mjs`.

Цель — проверять язык на разнообразных и смелых задачах, а не собирать
коллекцию одинаковых CRUD. Список идей не ограничен текущими возможностями
Arcod: если чего-то не хватает — это фиксируется в issue, а не отменяет идею. Найденные ограничения и баги уходят в issue
[`chubakur/arcod`](https://github.com/chubakur/arcod/issues).

Проект — это система: минимум две внешние системы (БД, очередь, S3, IAM, почта,
OLAP), а не «сервис + kv». Мелкие идеи откладываются в пользу крупных.

## Проекты

| # | Проект | Идея | Возможности Arc |
|---|--------|------|-----------------|
| 001 | [expense-splitter](001-expense-splitter/) | Совместные траты и балансы | `kv`, `ids`, типы-записи, ошибки, валидация |
| 002 | [webhook-inbox](002-webhook-inbox/) | Вебхуки: идемпотентность, очередь, повторы, DLQ | `kv`, `queue`, `jobs`, `ids`, retry, дедупликация |
| 003 | [collab-board](003-collab-board/) | Совместная доска: слияние правок без потерь | `kv`, `stream` (websocket), `ids`, идемпотентность |
| 004 | [turn-clock](004-turn-clock/) | Пошаговые партии: банк времени, таймауты, переподключение | `kv`, `stream`, `ids`, `datetime`, проекция журнала |
| 005 | [fence-locks](005-fence-locks/) | Распределённые аренды: fencing token, продление, guard от зависшего держателя | `kv`, `ids`, `unique` как атомарный claim, составные списки в examples |
| 006 | [mini-search](006-mini-search/) | Мини-поисковик: инвертированный индекс, BM25, сниппеты | `kv`, курсорная пагинация, составной `unique`, examples как тесты |
| 007 | [vector-store](007-vector-store/) | Векторное хранилище: IVF-индекс, фильтры по метаданным, гибридный текст | `kv`, `ids`, составной `unique`, k-means и ANN в песочнице `impl` |
| 009 | [report-pipeline](009-report-pipeline/) | Отчёт: S3 → очередь → консьюмер → MySQL, retry | `blob`, `queue`, `sql`, `ids`, outbox, consumer |

Очередь идей — [IDEAS.md](IDEAS.md). Журнал фидбека и перепроверка закрытых issue — [ISSUES.md](ISSUES.md).

## Структура каталога

```
NNN-slug/
  README.md   — описание, API, запуск, впечатления от Arc
  main.arc    — модель сервиса
  impl/*.mjs  — тела операций (песочница io)
  smoke.sh    — сборка, запуск, проверки по HTTP
```

## Требования

- Node.js >= 22.18
- Docker
- `arcod` из `chubakur/arcod` (`npm link` в корне того репозитория)

## Общие команды

```bash
cd NNN-slug
arcod check                 # модель и предупреждения
arcod build --impl          # генерация .arcod/build
arcod run --impl --port ... # docker compose
./smoke.sh                  # e2e-проверка проекта
```

Ветка и коммиты: `main`, тема коммита — `NNN: ...`.
