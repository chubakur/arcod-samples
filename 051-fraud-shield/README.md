# 051-fraud-shield: антифрод для платёжного шлюза

Система принимает платёжные попытки, оценивает их по набору правил и
внешнему скорингу, пишет решение и открывает кейс на ручную проверку с
доказательствами в S3. Это не «сервис + kv»: пять внешних систем, два
фоновых консьюмера и живой фид решений.

Ключевое разделение: HTTP-запрос **не ждёт** риск-вендора. authorize
проверяет вход, кладёт Attempt(pending) и публикует id в очередь; решение
принимает консьюмер, поэтому медленный вендор не тормозит кассу, а клиент
получает вердикт опросом или через websocket.

## Компоненты

```
  checkout
     │ POST /v1/merchants/:id/attempts
     ▼
┌───────────────────────────┐   publish score    ┌───────────────────────┐
│ FraudShield API (Node)    │ ─────────────────► │ redis (queue)         │
│ merchants, rules,         │                    │ score, notify         │
│ attempts, cases, report   │ ◄───────────────── │                       │
└─────┬──────────┬──────────┘     consume        └───────────┬───────────┘
      │          │                                           │
      │ SQL      │ evidence/report JSON            ┌─────────▼──────────┐
      ▼          ▼                                │ score (consumer)   │
┌───────────┐  ┌────────────────────┐             │ правила + вендор   │
│ postgres  │  │ minio (S3)         │             └─────┬───────┬──────┘
│ Merchant  │  │ evidence/<id>.json │                   │       │
│ Rule      │  │ reports/<day>.json │        io.remote  │       │ publish
│ Attempt   │  └────────────────────┘                   ▼       ▼
│ Decision  │                                  ┌──────────────┐ ┌────────────┐
│ Case      │                                  │ risk vendor  │ │ websocket  │
└───────────┘                                  │ HTTP :9096   │ │ topic risk │
      ▲                                        └──────────────┘ └────────────┘
      │                                                   │
      │            ┌──────────────────────┐               │
      └────────────│ notify (consumer)    │◄──────────────┘
                   │ кейс + evidence в S3 │   publish notify
                   └──────────────────────┘
```

### Компонент → provider

| Компонент | provider | Что делает |
|-----------|----------|------------|
| Состояние (Merchant, Rule, Attempt, Decision, Case) | sql → postgres | строки, unique-ключи, count/aggregate |
| Очередь (score, notify) | queue → redis | доставка из API в консьюмеры |
| Доказательства и отчёты | blob → s3 (minio) | evidence/<attemptId>.json, reports/<day>.json |
| Живой фид решений | stream → websocket | топик risk: решение и открытый кейс |
| Риск-вендор | endpoint → внешний HTTP | POST /v1/score через io.remote |
| Идентификаторы | ids → local | id попыток, решений, кейсов |

Пять внешних систем: postgres, redis, minio, риск-вендор, websocket. Вендор в
примере — mocks/risk.mjs на хосте (порт 9096); в проде это внутренний
anti-fraud API или облачный скоринг. endpoint переписывает localhost в
host.docker.internal (#42), поэтому спека и smoke не знают про Docker.

## Модель данных

* **Merchant** — имя (уникальное) и dailyLimit в минорных единицах; 0 —
  без дневного лимита.
* **Rule** — конфигурация, а не код: kind + action (review/decline).
  * blocklist — value равен отпечатку карты;
  * amount_limit — сумма больше threshold;
  * velocity — больше threshold попыток этой карты за windowSeconds;
  * score — внешний скор не ниже threshold.
  Decline всегда сильнее review: одна decline-rule отменяет approve.
* **Attempt** — одна попытка: мерчант, отпечаток карты, сумма, страна,
  clientRef (уникальный ключ идемпотентности), статус
  pending | approved | review | declined, скор, причины, число сработавших
  правил.
* **Decision** — ровно одно решение на попытку; unique attemptId — защита
  от повторного решения при переотправке сообщения.
* **Case** — кейс ручной проверки для review/declined: статус
  open | resolved, исполнитель, заметки, ключ доказательств. unique
  attemptId — один кейс на попытку.

Rule — данные, поэтому новый блоклист или лимит не требует релиза: следующий
же консьюмер читает актуальный набор.

## Как принимается решение

1. authorize валидирует сумму и отпечаток, проверяет мерчанта и
   идемпотентность по clientRef, вставляет Attempt(pending), публикует
   score.
2. Консьюмер score загружает попытку и все включённые правила, вызывает
   вендора **один раз** и считает:
   * blocklist — точное совпадение отпечатка;
   * amount_limit — amount > threshold;
   * velocity — io.count по cardFingerprint с окном
     createdAt >= now - windowSeconds (текущая попытка входит в счёт, поэтому
     правило «больше N» срабатывает на N+1-й);
   * score — vendor.score >= threshold;
   * дневной лимит мерчанта — io.aggregate(sum approved за UTC-сутки) +
     amount > dailyLimit (не счётчик, который может разойтись, а агрегат).
3. Итог: любая decline-rule → declined; иначе любое срабатывание или
   недоступность вендора → review; иначе approved.
4. Decision вставляется, Attempt обновляется, событие уходит в websocket
   risk. Для review/declined публикуется notify.
5. Консьюмер notify собирает {attempt, decision, merchant} в
   evidence/<attemptId>.json, создаёт Case(open) и объявляет его в фиде.
   Повторная доставка находит кейс и ничего не делает.

**Fail-closed.** Если вендор ответил 5xx или недоступен, попытка уходит в
review с причиной scoring_unavailable, никогда не в approved. «Не смогли
спросить» — не доказательство хорошего платежа.

## API

| Метод | Путь | Что |
|-------|------|-----|
| POST | /v1/merchants | создать мерчанта; дубль имени — 409, отрицательный лимит — 400 |
| GET | /v1/merchants | список мерчантов |
| POST | /v1/rules | добавить правило; дубль имени — 409, неизвестный kind — 400 |
| GET | /v1/rules | список правил |
| POST | /v1/merchants/:merchantId/attempts | принять попытку; тот же clientRef вернёт ту же попытку |
| GET | /v1/attempts?status=&limit= | журнал попыток |
| GET | /v1/attempts/:attemptId | попытка + решение + кейсы |
| GET | /v1/cases?status=open | очередь ручной проверки |
| POST | /v1/cases/:caseId/resolve | 200; повторный resolve — 409, чужая попытка — 404 |
| GET | /v1/cases/:caseId/evidence | JSON-доказательства из S3 (key, content, bytes) |
| POST | /v1/reports | собрать дневной JSON в S3; плохая дата — 400 |
| GET | /v1/stats | счётчики по статусам, средний скор, открытые кейсы |
| POST | /v1/sweep | переотправить зависшие pending старше 5 минут (вместо cron, #12) |
| GET | /v1/dead | dead-letter очередей score и notify |

Пример:

```bash
M=$(curl -sS -X POST localhost:8098/v1/merchants -H 'content-type: application/json' \
  -d '{"name":"shop-a","dailyLimit":100000}' | jq -r .id)
curl -sS -X POST localhost:8098/v1/rules -H 'content-type: application/json' \
  -d '{"name":"stolen-card","kind":"blocklist","action":"decline","value":"card-stolen"}'
A=$(curl -sS -X POST "localhost:8098/v1/merchants/$M/attempts" -H 'content-type: application/json' \
  -d '{"cardFingerprint":"card-stolen","amount":900,"clientRef":"order-77"}' | jq -r .id)
sleep 1
curl -sS "localhost:8098/v1/attempts/$A" | jq '{status:.attempt.status, reasons:.attempt.reasons, cases:(.cases|length)}'
```

## Запуск

```bash
cd 051-fraud-shield
./smoke.sh                     # вендор на хосте, сборка, запуск, все проверки
```

Вручную:

```bash
node mocks/risk.mjs &          # :9096
arcod check
arcod build --impl --port 8098
arcod run --impl --port 8098
# в другом терминале:
curl -sS localhost:8098/healthz
```

Остановка: arcod run --down --impl или
docker compose -f .arcod/build/docker-compose.yml down -v.

## Что проверяет smoke

Сборка, запуск, затем:

* мерчанты: 201, дубль 409, отрицательный лимит 400, неизвестный мерчант 404;
* четыре вида правил, дубль 409, неизвестный kind 400, пустой blocklist 400;
* обычная попытка: approved, скор 5, одна Decision, кейса нет, вендор
  вызван;
* идемпотентность: тот же clientRef возвращает ту же попытку, второй строки
  нет;
* blocklist: declined, кейс, доказательства в S3 с решением и отпечатком;
* сумма выше лимита: review с причиной amount_limit:60000>50000;
* страна XX: вендор 88, review с score:88>=70 и причиной вендора;
* вендор 503: review с scoring_unavailable и скором 0;
* velocity: три попытки проходят, четвёртая — review: velocity:4>3/600s;
* дневной лимит: 3000 + 3000 при лимите 5000 → review: daily_limit:6000>5000;
* кейс: resolve 200, повтор 409, неизвестный 404;
* отчёт за UTC-день: 11 попыток, 5 approved, 5 review, 1 declined,
  approvedAmount 4500, объект reports/<day>.json; плохая дата 400;
* статистика: счётчики, средний скор, 5 открытых кейсов;
* websocket: решение по новой попытке приходит подписчику топика risk;
* sweep идемпотентен (0 stale), dead-letter пуст, валидация суммы и отпечатка.

## Опыт использования Arc

Что сработало хорошо:

* **SQL-агрегаты вместо счётчиков.** Дневной лимит — io.aggregate(sum) по
  approved-строкам, velocity — io.count с диапазоном createdAt. Не нужны
  поля-счётчики, которые расходятся при повторе; unique-ключи на
  Decision.attemptId и Case.attemptId делают консьюмеры идемпотентными
  бесплатно.
* **Очередь как граница.** Медленный вендор не влияет на latency кассы;
  authorize — это insert + publish.
* **endpoint + host.docker.internal** (#42): вендор на хосте работает без
  правок спеки.
* **stream** даёт операторам живой фид без polling-эндпоинта.
* **sql + postgres** прошёл миграции и duplicate-insert (409) без сюрпризов
  (#43, #54 закрыты).

Чего не хватило (issue уже есть, новых не заводил — все пробелы покрыты):

* **#63 / A094.** TTL-кэш для blocklist и счётчиков окна рядом с sql-сервисом
  недоступен: bind cache -> redis при uses store: sql отклоняется. Поэтому
  все проверки читают Postgres. Для антифрода это архитектурно больно:
  velocity-запросы — самая горячая точка, и кэш напрашивается сам.
* **#12.** У job нет cron: sweep — публичный POST с явным now, его
  вызывает внешний runner.
* **#58.** update без предусловия: resolveCase читает статус и обновляет
  строку; два ревьюера могут оба пройти проверку. В примере это названо в
  коде; гонку закрыл бы CAS или unique на решение.
* **#56.** Идемпотентный повтор POST с тем же clientRef возвращает ту же
  попытку, но всегда с 201: объявить 200 нельзя.
* **#53.** Ответ файлом из S3 отдаётся записью {key, content, bytes}, а не
  байтами с content-type; клиент разворачивает JSON сам.
* **#48.** io.blobPut принимает только строку: доказательства — JSON-текст,
  бинарные скриншоты пришлось бы кодировать base64.
* **#59.** Консьюмер обязан вернуть объект: undefined считается падением и
  уводит сообщение в dead-letter, хотя работа уже сделана.

Осознанные ограничения примера:

* API внутренний, без identity: роли ревьюера и мерчанта не разделены.
  В проде сюда просится Keycloak, как в 048/049.
* Отпечаток карты приходит от клиента. Детерминированного/keyed-хеша в
  Arcod нет (io.hash — salted scrypt для проверки пароля), поэтому PAN
  хеширует вызывающая сторона. Это не блокер, но язык пока не умеет
  псевдонимизацию сам.
* Дневной отчёт читает максимум 500 строк (find), это страница, а не
  полный проход. Для больших объёмов нужен OLAP (#26) или keyset-обход.
