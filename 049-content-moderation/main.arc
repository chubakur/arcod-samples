module content_moderation @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.identity @1
use capability arcod.std.ids @1

// Human reviewers. The first person to register bootstraps the platform as an
// admin; after that only an admin may grant roles. A reviewer may decide and a
// senior may resolve appeals.
type Reviewer = {
  id: string,
  userId: string,
  name: string,
  role: string,
  createdAt: datetime
}

// A policy version is immutable once active: changing the rules means a new
// version, and the rescreen consumer re-evaluates everything an older policy
// auto-approved. terms is a comma-separated list, linkWeight scores every URL,
// threshold is the risk at which a human must look.
type Policy = {
  id: string,
  version: int,
  name: string,
  terms: string,
  linkWeight: int,
  threshold: int,
  active: bool,
  createdBy: string,
  createdAt: datetime
}

// One submitted piece of content. status: screening | pending | approved |
// rejected | appealed. decidedBy is either policy:vN (automatic) or a user id.
// evidenceKey points at the screening snapshot in S3.
type Item = {
  id: string,
  author: string,
  authorName: string,
  kind: string,
  text: string,
  status: string,
  risk: int,
  flags: string,
  policyVersion: int,
  reason: string,
  decidedBy: string,
  createdAt: datetime,
  updatedAt: datetime,
  decidedAt: datetime?,
  dueAt: datetime?,
  escalated: bool,
  evidenceKey: string
}

type Decision = {
  id: string,
  itemId: string,
  reviewer: string,
  reviewerName: string,
  decision: string,
  reason: string,
  createdAt: datetime
}

// An appeal may be filed once per item; resolvedAt/escalated make the sweep
// idempotent.
type Appeal = {
  id: string,
  itemId: string,
  author: string,
  reason: string,
  status: string,
  createdAt: datetime,
  resolvedAt: datetime?,
  resolvedBy: string,
  escalated: bool
}

// id is deterministic (ev:<item>:<user>:<status>) so consumer redelivery cannot
// duplicate a notification.
type Notification = {
  id: string,
  userId: string,
  itemId: string,
  kind: string,
  text: string,
  readAt: datetime?,
  createdAt: datetime
}

type Audit = {
  id: string,
  actor: string,
  action: string,
  itemId: string,
  detail: string,
  at: datetime
}

type ItemView = {
  item: Item,
  decisions: list<Decision>,
  appeals: list<Appeal>
}

type EvidenceFile = {
  key: string,
  content: string,
  bytes: int
}

type Stats = {
  total: int,
  pending: int,
  approved: int,
  rejected: int,
  appealed: int,
  autoApproved: int,
  escalated: int,
  openAppeals: int
}

type SweepResult = {
  escalated: int,
  appeals: int
}

type RescreenResult = {
  changed: int
}

error Unauthorized
error Invalid
error Conflict
error NotFound
error Forbidden

service Moderation : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses auth: identity
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.remove, store.find, store.count, events.publish, events.dead, files.put, files.get, auth.actor, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Reviewer.userId
    unique Policy.version
    unique Appeal.itemId
    unique Decision.itemId
  }

  contract {
    // ---- reviewers and policies ------------------------------------------

    // The first caller becomes admin whatever role was asked for. Later callers
    // may only self-register as a plain reviewer; a repeated call for the same
    // user returns the row.
    auth op registerReviewer(name: string, role: string = "reviewer") -> Reviewer {
      route: "POST /v1/reviewers"
      effects: store.find, store.insert, auth.actor, uuid.new
      errors: Unauthorized, Invalid, Forbidden, Conflict
      on error Unauthorized: name != null
      post: result.id != null
      on error Invalid: name != null
      on error Forbidden: role != null
      on error Conflict: name != null
    }

    // Only an admin changes roles. The last admin cannot demote himself into a
    // deployment with no administrator.
    auth op setRole(reviewerId: string, role: string) -> Reviewer {
      route: "POST /v1/reviewers/:reviewerId/role"
      effects: store.fetch, store.find, store.update, auth.actor
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: reviewerId != null
      post: result.id != null
      on error NotFound: reviewerId != null
      on error Forbidden: role != null
      on error Invalid: role != null
      on error Conflict: reviewerId != null
    }

    // A new version always becomes the active one; older rows stay for audit.
    // The rescreen event makes auto-approved content face the new rules.
    auth op createPolicy(name: string, terms: string, linkWeight: int = 10, threshold: int = 50) -> Policy {
      route: "POST /v1/policies"
      effects: store.find, store.update, store.insert, events.publish, auth.actor, uuid.new
      errors: Unauthorized, Invalid, Forbidden, Conflict
      on error Unauthorized: name != null
      post: result.id != null
      on error Invalid: name != null
      on error Forbidden: terms != null
      on error Conflict: name != null
    }

    auth op policies() -> list<Policy> {
      route: "GET /v1/policies"
      effects: store.find, auth.actor
      errors: Unauthorized
      on error Unauthorized: result != null
      post: result != null
    }

    // ---- content and decisions -------------------------------------------

    // The API only accepts the text: scoring, evidence and routing happen in
    // the screen consumer, so submit stays fast.
    auth op submit(kind: string, text: string) -> Item {
      route: "POST /v1/items"
      effects: store.insert, events.publish, auth.actor, uuid.new
      errors: Unauthorized, Invalid
      on error Unauthorized: kind != null
      post: result.id != null
      on error Invalid: text != null
    }

    auth op myItems(limit: int = 50) -> list<Item> {
      route: "GET /v1/items"
      effects: store.find, auth.actor
      errors: Unauthorized
      on error Unauthorized: limit != null
      post: result != null
    }

    auth op item(itemId: string) -> ItemView {
      route: "GET /v1/items/:itemId"
      effects: store.fetch, store.find, auth.actor
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: itemId != null
      post: result.item.id != null
      on error NotFound: itemId != null
      on error Forbidden: itemId != null
    }

    auth op queue(status: string = "pending", limit: int = 50) -> list<Item> {
      route: "GET /v1/queue"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden, Invalid
      on error Unauthorized: status != null
      post: result != null
      on error Forbidden: status != null
      on error Invalid: status != null
    }

    // A second decision is a conflict: the reviewer is looking at a stale row.
    auth op decide(itemId: string, decision: string, reason: string = "") -> Item {
      route: "POST /v1/items/:itemId/decision"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: itemId != null
      post: result.id != null
      on error NotFound: itemId != null
      on error Forbidden: itemId != null
      on error Invalid: decision != null
      on error Conflict: itemId != null
    }

    // Named contentDecision to avoid the reserved-looking name "decision".
    auth op contentDecision(itemId: string) -> Decision {
      route: "GET /v1/items/:itemId/decision"
      effects: store.find, auth.actor
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: itemId != null
      post: result.id != null
      on error NotFound: itemId != null
      on error Forbidden: itemId != null
    }

    // ---- appeals ---------------------------------------------------------

    // Only the author may appeal, and only a rejected item; one appeal per item
    // is enforced by a unique rule as well as the status check.
    auth op appeal(itemId: string, reason: string) -> Appeal {
      route: "POST /v1/items/:itemId/appeal"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: itemId != null
      post: result.id != null
      on error NotFound: itemId != null
      on error Forbidden: itemId != null
      on error Invalid: reason != null
      on error Conflict: itemId != null
    }

    auth op appeals(status: string = "open", limit: int = 50) -> list<Appeal> {
      route: "GET /v1/appeals"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden, Invalid
      on error Unauthorized: status != null
      post: result != null
      on error Forbidden: status != null
      on error Invalid: status != null
    }

    auth op resolveAppeal(appealId: string, outcome: string, note: string = "") -> Appeal {
      route: "POST /v1/appeals/:appealId/resolve"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: appealId != null
      post: result.id != null
      on error NotFound: appealId != null
      on error Forbidden: appealId != null
      on error Invalid: outcome != null
      on error Conflict: appealId != null
    }

    // ---- read models and operations --------------------------------------

    auth op notifications(unread: bool = false) -> list<Notification> {
      route: "GET /v1/notifications"
      effects: store.find, auth.actor
      errors: Unauthorized
      on error Unauthorized: result != null
      post: result != null
    }

    auth op readNotification(id: string) -> Notification {
      route: "POST /v1/notifications/:id/read"
      effects: store.fetch, store.update, auth.actor
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: id != null
      post: result.id != null
      on error NotFound: id != null
      on error Forbidden: id != null
    }

    auth op evidence(itemId: string) -> EvidenceFile {
      route: "GET /v1/items/:itemId/evidence"
      effects: store.fetch, files.get, auth.actor
      errors: Unauthorized, NotFound, Forbidden, Conflict
      on error Unauthorized: itemId != null
      post: result.key != null
      on error NotFound: itemId != null
      on error Forbidden: itemId != null
      on error Conflict: itemId != null
    }

    auth op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: result != null
      post: result.total >= 0
      on error Forbidden: result != null
    }

    auth op auditTrail(limit: int = 50) -> list<Audit> {
      route: "GET /v1/audit"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: limit != null
      post: result != null
      on error Forbidden: limit != null
    }

    // No cron in Arcod (#12): the runner calls sweep with an explicit instant.
    // Escalation is sticky, so a second sweep for the same moment is a no-op.
    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, store.update, store.insert, uuid.new
      errors: none
      post: result.escalated >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // ---- consumers -------------------------------------------------------

    // Consumer 1: score, snapshot to S3, route. Clean content is approved
    // automatically; risky content waits for a human with a 24h due date.
    job screen(itemId: string) {
      on: events.screen
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, files.put, events.publish, uuid.new
      errors: none
    }

    // Consumer 2: fan out one notification per (item, user, status). The row id
    // is deterministic, so a redelivered job inserts nothing.
    job notify(itemId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, uuid.new
      errors: none
    }

    // Consumer 3: a new policy pulls back content an older policy auto-approved
    // when the new rules score it above the threshold.
    job rescreen(policyId: string) {
      on: events.rescreen
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, files.put, events.publish, uuid.new
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind auth -> keycloak(host: "idp", import: "realm.json")
  bind uuid -> local
  deploy docker
}
