# 017 — Contract signing

A document-signing workflow: a sender uploads the document, names the people who
must sign in order, and the service invites them one at a time. Every signature
is bound to the document bytes, the address and the instant; the last signature
seals a manifest into S3. A sealed envelope can be verified later, and an edited
document is detected instead of silently accepted.

This is a system, not a CRUD demo: four external systems, two background
consumers, an ordered state machine and an audit trail.

## Components

| Component | Capability | Provider | Image / endpoint |
|-----------|------------|----------|------------------|
| Envelope, signer, audit, notification rows | `arcod.std.sql` | `mysql` | `mysql:8.4` |
| `mail` and `seal` topics | `arcod.std.queue` | `redis` | `redis:7-alpine` |
| Document + sealed manifest | `arcod.std.blob` | `s3` | `minio/minio` |
| Invitations, reminders, decline notices | `endpoint` (external service `Mailer`) | `endpoint` | `mock/mailbox.mjs` on the compose network |
| Ids | `arcod.std.ids` | `local` | — |

The mail gateway is an ordinary external service (`external service Mailer`), so
the same spec can bind a real provider without touching a body. In the smoke run
it is the service image with another entrypoint, joined to the compose network
under the alias `mailer`.

```
POST /v1/envelopes ──► document ──► S3
        │
        ▼
   envelope (draft) ──addSigner──► signer 1..n (ordered)
        │
      send ──► queue: mail(invite #1)
        │
   mail consumer ──► Mailer ──► invite code
        │
      sign #1 ──► signature = sha256(document|email|at)
        │            ├── next signer ──► queue: mail(invite #2)
        │            └── last signer ──► queue: seal
        ▼
   seal consumer ──► manifest.json ──► S3 ──► envelope completed
        │
   GET .../manifest ──► re-read S3, verify every signature
```

## State machine

```
draft ──send──► sent ──sign(1 of n)──► in_progress ──sign(last)──► sealing ──seal──► completed
  │                │                        │
  │                └────────decline─────────┴──► declined   (later signers become skipped)
  └──addSigner (draft only)
```

Only the signer whose turn it is may sign; the invitation code from the email is
required, so a leaked envelope id is not enough. A second signature by the same
person is a `409`, not a second row: at-least-once queue delivery cannot corrupt
the route.

## API

| Method | Route | What it does |
|--------|-------|--------------|
| POST | `/v1/envelopes` | create a draft; the document goes to S3 (max 512 KB) |
| POST | `/v1/envelopes/:id/signers` | append a signer; the server assigns the turn |
| POST | `/v1/envelopes/:id/send` | start the route, invite the first signer |
| GET | `/v1/envelopes/:id` | envelope + ordered signers + audit trail |
| POST | `/v1/envelopes/:id/sign` | sign as the current signer (`email`, `code`) |
| POST | `/v1/envelopes/:id/decline` | refuse with a reason; closes the envelope |
| POST | `/v1/envelopes/:id/remind` | reminder tick (`afterSec`, default 3600) |
| GET | `/v1/envelopes/:id/manifest` | sealed manifest with `intact` and `verified` |
| GET | `/v1/stats` | counters |
| POST | `/v1/dev/envelopes/:id/tamper` | test hook: replace the stored document |

Errors: `400 Invalid`, `403 Forbidden` (unknown address or wrong code),
`404 NotFound`, `409 Conflict` (wrong turn, already signed, already sent,
reminder inside the window).

## How the signatures work

`signature = sha256(documentText + "|" + email + "|" + signedAt)`.

The digest is stored on the signer row; the sealed manifest copies it. The
manifest route re-reads the document from S3 and recomputes every digest, so:

- `intact` — the manifest bytes in S3 still hash to the value recorded on the
  envelope (the seal was not edited);
- `verified` — every signature matches the document as stored **today**.

Editing the document keeps `intact: true` and flips `verified` to `false` —
which is exactly what the tamper step of `smoke.sh` proves.

Hashes are computed with the platform `crypto.subtle` because a body cannot
import `node:crypto` and the `hash` capability is not wired into the runtime
([issue #44](https://github.com/chubakur/arcod/issues/44)).

## Run

```bash
arcod check
arcod build --impl --port 8095
arcod run --impl --port 8095        # compose: mysql + redis + minio + service
./smoke.sh                          # builds, runs, drives the whole flow, PASS
arcod run --down --impl             # or: docker compose -f .arcod/build/docker-compose.yml down -v
```

`smoke.sh` needs `jq` and Docker. It starts the mail gateway on port 9097; set
`MAIL_PORT`/`PORT` to move it. Without Docker the run is not possible: the
service needs MySQL, Redis and S3.

## Что проверяет smoke

1. create: 201, document size stored, invalid title/owner 400, readable view;
2. signers: server-assigned turns 1/2, duplicate address 409;
3. send: `sent`, second send 409, signer after send 409, invite mail carries a code;
4. sign: out of turn 409, wrong code 403, stranger 403, first signature →
   `in_progress`, repeat 409, second signer invited with a different code;
5. remind: 200 with `afterSec: 0`, 409 inside the window, the reminder mail lands;
6. seal: the consumer moves the envelope to `completed`, audit has
   `created, signer_added, sent, signed, reminded, sealed`;
7. manifest: `intact` and `verified` true, both signatures verified;
8. tamper: `intact` true, `verified` false;
9. decline: `declined`, reason stored, later signer `skipped`, manifest 409,
   owner notified;
10. stats and 404s.

## Опыт использования Arc

**Что получилось хорошо.** Порядок подписантов и состояния — это данные, а не
код: всё уложилось в четыре записи (`Envelope`, `Signer`, `Audit`,
`Notification`) и два консьюмера. Декларация эффектов по операциям оказалась
полезной: когда `sign` понадобился доступ к документу, `files.get` пришлось
добавить явно, и это сразу показало, что операция читает объект. `403` для
чужого кода и `409` для не своей очереди читаются как нормальный API, а
`on error`-правила заставляют описать предусловия.

**Чего не хватило.**

- **`hash`-capability без рантайма.** `check` принимает
  `use capability arcod.std.hash`, `bind sig -> local` и эффекты
  `sig.hash/sig.verify`, но сгенерированный сервис не содержит `io.hash`:
  первый же вызов — `500`, в логе `TypeError: io.hash is not a function`.
  Пришлось считать sha256 через `crypto.subtle` прямо в теле ([#44](https://github.com/chubakur/arcod/issues/44)).
- **Хелперы в телах.** Тела операций делят один модуль: две функции с одним
  именем в разных `impl/*.mjs` дают `A093` на `check`. Хелпер пришлось
  дублировать под разными именами — это терпимо, но общий модуль хелперов
  пригодился бы.
- **Нет расписания для операций** (issue #12): напоминания пришлось сделать
  тиком `POST /remind` с `afterSec`, хотя по смыслу это cron-workflow.
- **Нет типа для карты метаданных**: аудит пришлось свести к
  `kind/actor/detail` строками.
- `W012` (нет примеров у операций) висит на всех десяти операциях: примеры в
  спеке пока не пишутся, а `smoke.sh` их заменяет.

## Файлы

```
main.arc               спецификация: типы, 10 операций, 2 job, окружение
impl/*.mjs             тела: create, addSigner, send, sign, decline, remind,
                       manifest, stats, tamper, deliver, seal
mock/mailbox.mjs       почтовый шлюз для smoke (пишет письма в память)
smoke.sh               сборка + запуск + HTTP-проверки, в конце PASS
```
