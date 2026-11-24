# Идеи проектов

Очередь идей для новых примеров. Автоматизация берёт первую со статусом `todo`
и реализует её. Список — стартовая точка, а не потолок: безумные идеи
приветствуются.

**Правило масштаба.** Проект — это система, а не «сервис + kv». Каждая строка
`todo` обязана иметь **минимум две внешние системы** (БД, очередь, S3, IAM,
почта, OLAP, внешний сервис). Цель — 3–5 провайдеров и хотя бы один фоновый
консьюмер или внешний вызов. Если идея укладывается в один kv/sql — она не
попадает в очередь. В README примера — таблица «компонент → provider».

Если для идеи не хватает возможности Arcod (типа, эффекта, провайдера,
генератора, семантики) — не повод отказаться: делаем сколько язык позволяет
сегодня, остальное в README и issue. `blocked` — если не работает вообще,
`partial` — если работает урезанно.

| # | Идея | Интеграции (мин. 2) | Статус |
|---|------|---------------------|--------|
| 001 | Expense splitter: совместные траты и балансы | — | done — [001-expense-splitter](001-expense-splitter/) |
| 002 | Webhook inbox: приём событий, идемпотентность, повторная доставка | — | done — [002-webhook-inbox](002-webhook-inbox/) |
| 003 | Совместная доска: комнаты, фигуры, слияние правок без потерь | — | done — [003-collab-board](003-collab-board/) |
| 004 | Мультиплеерный сервер пошаговой игры: комнаты, ходы, таймауты | — | done — [004-turn-clock](004-turn-clock/) |
| 005 | Распределённые блокировки: аренда, fencing token, продление | — | done — [005-fence-locks](005-fence-locks/) |
| 006 | Мини-поисковик: инвертированный индекс, BM25, сниппеты | — | done — [006-mini-search](006-mini-search/) |
| 007 | Векторное хранилище: эмбеддинги, IVF-индекс, фильтры | — | done — [007-vector-store](007-vector-store/) |
| 008 | Движок workflow: состояния, таймеры, ретраи, компенсации | — | done — [008-flow-engine](008-flow-engine/) |
| 009 | Report pipeline: S3 → outbox → RabbitMQ → консьюмер → MySQL | blob, queue, sql | done — [009-report-pipeline](009-report-pipeline/) |
| 010 | Time-series API: приём через очередь, downsampling, retention | olap, queue, sql | partial — [011-metric-lake](011-metric-lake/) (olap нет в языке, #26; холодный слой — S3) |
| 011 | Email-to-API мост: письмо → вебхук, вложение в S3, журнал | mail, blob, sql | done — [038-email-to-api](038-email-to-api/) (mail — внешний HTTP-провайдер: у capability нет эффектов, #33) |
| 012 | Feature store: online/offline консистентность, версии фич | sql, kv, olap | todo |
| 013 | Зоны доставки: полигоны и тарифы, кэш, геокодер | sql, kv, endpoint | todo |
| 014 | Подписки и биллинг: пратейшн, dunning, счета, чеки | sql, queue, endpoint, mail | done — [013-billing-dunning](013-billing-dunning/) (proration нет, mail не подключён — #33, отложенный dunning — #12) |
| 015 | Anti-fraud: velocity-правила, лимиты, внешний скоринг | kv, olap, endpoint | todo — ждёт #37 (`kv` пишет в SQL) и #34 (`io.aggregate`), иначе счётчики врёт |
| 016 | API-gateway: роутинг, ключи, квоты, журнал доступа | endpoint, kv, olap | todo |
| 017 | Подписание документов: конверты, порядок, аудит, письма | sql, queue, blob, endpoint (mail) | done — [017-contract-signing](017-contract-signing/) |
| 018 | Лента рекомендаций: коллаборативная фильтрация, снапшоты моделей | olap, sql, blob | todo |
| 019 | GDPR-стирание: каскадный поиск PII и удаление по заданию | queue, sql, blob, endpoint | done — [015-gdpr-erasure](015-gdpr-erasure/) (kv заменён на строку аудита: #37) |
| 020 | Аукцион: ставки, антиснайпинг, закрытие лота, уведомления | sql, queue, mail | done — [016-auction](016-auction/) (mail — внешний endpoint: провайдера mail нет) |
| 021 | Коллаборативный редактор: OT/CRDT, курсоры, история версий | stream, sql, blob | todo |
| 022 | Планировщик встреч: слоты, часовые пояса, приглашения | sql, mail, queue | todo |
| 023 | Пайплайн CSV→отчёт: валидация, дедуп, агрегаты, ошибки | blob, queue, sql, olap | todo |
| 024 | Прокси-кэш внешнего API: TTL, stale-while-revalidate, метрики | endpoint, kv, olap | todo |
| 025 | Модерация контента: очередь, роли, решения, апелляции | queue, identity, sql, mail | todo |
| 026 | Оркестратор LLM-агентов: инструменты, шаги, бюджет токенов | llm, sql, queue, blob | todo |
| 027 | Склад: резервы и партии, истечение брони, уведомления | sql, queue, mail | todo |
| 028 | Тарифы SaaS: метеринг, счета, перерасход, чеки | olap, sql, queue, mail | todo |
| 029 | Каталог: варианты и SKU, картинки, кэш витрины | sql, blob, kv | todo |
| 030 | Событийный лог: append-only, проекции, переигрывание, аналитика | sql, queue, olap | todo |
| 031 | Матчмейкер: рейтинг, очередь, подбор состава, отмена | queue, kv, sql | todo |
| 032 | Календарь слотов: пересечение часовых поясов, перенос, письма | sql, mail, queue | todo |
| 033 | Прямая загрузка в S3: подписанные ссылки, квоты, сироты | blob, identity, sql | todo |
| 034 | Видеоплатформа: S3, очередь транскодинга, статусы, ссылки | blob, queue, sql, identity | done — [014-video-platform](014-video-platform/) |
| 035 | Магазин: каталог, заказы в очередь, оплата внешним сервисом, картинки | sql, queue, blob, endpoint, identity | partial — [010-shop-checkout](010-shop-checkout/) (sql, queue, blob, endpoint + consumer; IAM не подключён, find сломан) |
| 036 | Центр уведомлений: шаблоны, fan-out, почта, ретраи, аналитика | sql, queue, blob, endpoint, ids | done — [036-notification-center](036-notification-center/) (OLAP заменён строками в SQL: адаптера clickhouse нет, #26) |
| 037 | Приём данных: CSV в S3, задания, агрегаты в ClickHouse, отчёты | blob, queue, olap, sql | todo |
| 038 | Мультитенантный SaaS: IAM, изоляция, квоты, аудит, письма | identity, sql, kv, mail | todo |
| 039 | Совместная работа: поток, БД, вложения в S3, присутствие | stream, sql, blob, kv | todo |
| 040 | Подписание документов: S3, IAM, аудит, приглашения, напоминания | blob, identity, sql, mail, queue | todo |
| 041 | CI-оркестратор: очередь прогонов, артефакты в S3, статусы, отмена | queue, blob, sql, endpoint | done — [037-ci-orchestrator](037-ci-orchestrator/) |
| 042 | Биллинг: подписки, метеринг в OLAP, счета, чеки | sql, olap, queue, mail | todo |
| 043 | IoT-платформа: поток телеметрии, правила, алерты, история | stream, olap, mail, kv | todo |
| 044 | Диспетчер выездов: заявки, автоподбор техника, фото в S3, уведомления | sql, queue, blob, endpoint | done — [012-field-dispatch](012-field-dispatch/) |
