module fraud_shield @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.stream @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

// A merchant is the account being protected: every attempt belongs to one,
// and its dailyLimit is the amount of approved money per calendar day before
// the next attempt goes to manual review instead of straight through.
type Merchant = {
  id: string,
  name: string,
  dailyLimit: int,
  createdAt: datetime
}

// A rule is configuration, not code: kind decides which field matters.
//   blocklist     - value equals the card fingerprint (decline)
//   amount_limit  - amount above threshold (action)
//   velocity      - more than threshold attempts of this card in windowSeconds
//   score         - external score at or above threshold
// action is what a hit does: review or decline. A decline always wins.
type Rule = {
  id: string,
  name: string,
  kind: string,
  value: string,
  threshold: int,
  windowSeconds: int,
  action: string,
  enabled: bool,
  createdAt: datetime
}

// One payment attempt. status: pending | approved | review | declined.
// clientRef is the idempotency key; it is unique because a retried request
// must not create a second attempt (and therefore a second score).
type Attempt = {
  id: string,
  merchantId: string,
  clientRef: string,
  cardFingerprint: string,
  customerEmail: string,
  amount: int,
  currency: string,
  country: string,
  status: string,
  score: int,
  reasons: string,
  ruleHits: int,
  createdAt: datetime,
  decidedAt: datetime?
}

// The scoring consumer writes exactly one decision per attempt. The unique
// rule is the guard against a redelivered message deciding twice.
type Decision = {
  id: string,
  attemptId: string,
  outcome: string,
  score: int,
  reasons: string,
  rulesApplied: int,
  decidedAt: datetime
}

// Manual review. unique attemptId: an attempt has at most one case; a repeat
// notification finds the open one instead of opening a second queue item.
type Case = {
  id: string,
  attemptId: string,
  outcome: string,
  status: string,
  assignee: string,
  notes: string,
  evidenceKey: string,
  openedAt: datetime,
  resolvedAt: datetime?
}

type AttemptDetail = {
  attempt: Attempt,
  decision: list<Decision>,
  cases: list<Case>
}

type Stats = {
  attempts: int,
  pending: int,
  approved: int,
  review: int,
  declined: int,
  avgScore: float,
  openCases: int
}

type ReportFile = {
  key: string,
  content: string,
  bytes: int
}

type EvidenceFile = {
  key: string,
  content: string,
  bytes: int
}

type SweepResult = {
  stale: int,
  rescored: int
}

type RiskReply = {
  score: int,
  reasons: string,
  model: string
}

// The external risk vendor. The payload is an opaque JSON string so a vendor
// schema change does not become an Arcod type change; the reply is declared
// because the score and the reasons drive the decision.
external service RiskService : http {
  contract {
    op score(payload: string) -> RiskReply {
      route: "POST /v1/score"
    }
  }
}

error Invalid
error NotFound
error Conflict

service FraudShield : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses live: stream
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, store.aggregate, events.publish, events.dead, live.publish, files.put, files.get, RiskService.score, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Merchant.name
    unique Rule.name
    unique Attempt.clientRef
    unique Decision.attemptId
    unique Case.attemptId
  }

  contract {
    // ---- configuration ---------------------------------------------------

    public op createMerchant(name: string, dailyLimit: int = 100000) -> Merchant {
      route: "POST /v1/merchants"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op merchants() -> list<Merchant> {
      route: "GET /v1/merchants"
      effects: store.find
      errors: none
      post: result != null
    }

    // Rules are evaluated by the scoring consumer, not by this operation:
    // adding a blocklist entry takes effect for the next queued attempt.
    public op createRule(name: string, kind: string, action: string = "review", value: string = "", threshold: int = 0, windowSeconds: int = 0) -> Rule {
      route: "POST /v1/rules"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op rules() -> list<Rule> {
      route: "GET /v1/rules"
      effects: store.find
      errors: none
      post: result != null
    }

    // ---- payments --------------------------------------------------------

    // The API only records the attempt and wakes the scorer. Nothing that
    // talks to the risk vendor happens inside the request, so a slow vendor
    // does not slow the checkout; the client polls or listens on the feed.
    // The same clientRef returns the attempt that already exists.
    public op authorize(merchantId: string, cardFingerprint: string, amount: int, clientRef: string = "", customerEmail: string = "", currency: string = "RUB", country: string = "RU") -> Attempt {
      route: "POST /v1/merchants/:merchantId/attempts"
      effects: store.fetch, store.find, store.insert, events.publish, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: amount != null
      on error NotFound: merchantId != null
      on error Conflict: clientRef != null
    }

    public op attempts(status: string = "", limit: int = 50) -> list<Attempt> {
      route: "GET /v1/attempts"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    public op attempt(attemptId: string) -> AttemptDetail {
      route: "GET /v1/attempts/:attemptId"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.attempt.id != null
      on error NotFound: attemptId != null
    }

    // ---- review queue ----------------------------------------------------

    public op cases(status: string = "open", limit: int = 50) -> list<Case> {
      route: "GET /v1/cases"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    // 200: resolving is an action on an existing case, not a creation.
    // A second resolve is a conflict - the notes of the first one stay put.
    public op resolveCase(caseId: string, assignee: string = "", notes: string = "") -> Case {
      route: "POST /v1/cases/:caseId/resolve"
      status: 200
      effects: store.fetch, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: caseId != null
      on error Conflict: caseId != null
    }

    // The evidence bundle the notifier wrote to S3: attempt, decision,
    // merchant and the rule snapshot at decision time.
    public op caseEvidence(caseId: string) -> EvidenceFile {
      route: "GET /v1/cases/:caseId/evidence"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: caseId != null
    }

    // ---- operations ------------------------------------------------------

    // A day report is a real object in S3, not a reshaped response: the
    // caller gets the key and the bytes that were written.
    public op report(day: string) -> ReportFile {
      route: "POST /v1/reports"
      effects: store.find, store.aggregate, files.put
      errors: Invalid
      post: result.key != null
      on error Invalid: day != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.aggregate, store.find
      errors: none
      post: result.attempts >= 0
    }

    // No cron for jobs (#12): an external runner calls sweep with an explicit
    // instant. A pending attempt older than five minutes is republished; the
    // consumer is idempotent, so a duplicate wake-up is harmless.
    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, events.publish
      errors: none
      post: result.stale >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // ---- consumers -------------------------------------------------------

    // Consumer 1: evaluate every enabled rule, call the vendor once, write
    // one Decision, publish the outcome. A vendor failure is fail-closed:
    // the attempt goes to review with scoring_unavailable, never approved.
    job score(attemptId: string) {
      on: events.score
      retry: 2
      effects: store.fetch, store.find, store.count, store.aggregate, store.insert, store.update, events.publish, live.publish, RiskService.score, uuid.new
      errors: none
    }

    // Consumer 2: open the review case, write the evidence bundle to S3 and
    // announce it. Only review/declined attempts get a case; approved ones
    // have nothing for a human to do.
    job notify(attemptId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, files.put, live.publish, uuid.new
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind live -> websocket()
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  // localhost is rewritten for an endpoint binding: the container reaches the
  // host mock through host.docker.internal (#42).
  bind RiskService -> endpoint(url: "http://localhost:9096")
  deploy docker
}
