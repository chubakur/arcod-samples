module support_desk @0.1.0 {
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

// A tenant is the isolation boundary. Every record below carries tenantId and
// every operation resolves the caller's membership before it touches a row.
type Tenant = {
  id: string,
  slug: string,
  name: string,
  inviteCode: string,
  openLimit: int,
  createdAt: datetime
}

// The one place a user's role inside a tenant lives. Roles are local to the
// tenant, not realm roles: the same person may own one workspace and be a plain
// requester in another.
type Member = {
  id: string,
  tenantId: string,
  userId: string,
  name: string,
  role: string,
  createdAt: datetime
}

// status: open | pending | resolved. priority: low | normal | high.
// breachAlerted is the sweep's idempotency flag: one breach, one notification.
type Ticket = {
  id: string,
  tenantId: string,
  requester: string,
  requesterName: string,
  assignee: string,
  subject: string,
  body: string,
  status: string,
  priority: string,
  slaDueAt: datetime,
  createdAt: datetime,
  updatedAt: datetime,
  resolvedAt: datetime?,
  firstReplyAt: datetime?,
  breachAlerted: bool,
  messageCount: int,
  attachmentCount: int,
  lastMessageId: string
}

// internal notes are visible to staff only; the requester gets the public thread.
type Message = {
  id: string,
  ticketId: string,
  tenantId: string,
  author: string,
  authorName: string,
  internal: bool,
  body: string,
  createdAt: datetime
}

type Attachment = {
  id: string,
  ticketId: string,
  tenantId: string,
  name: string,
  size: int,
  key: string,
  uploadedBy: string,
  createdAt: datetime
}

// Notification rows are written by the notify consumer, not by HTTP. Their id
// is deterministic (<messageId>:<userId>) so a redelivery inserts nothing.
type Notification = {
  id: string,
  tenantId: string,
  ticketId: string,
  userId: string,
  kind: string,
  text: string,
  readAt: datetime?,
  createdAt: datetime
}

type Audit = {
  id: string,
  tenantId: string,
  ticketId: string,
  actor: string,
  action: string,
  detail: string,
  at: datetime
}

// status: queued | ready. The row appears before the object exists, so a client
// polls a real record instead of guessing an S3 key.
type Export = {
  id: string,
  tenantId: string,
  status: string,
  key: string,
  tickets: int,
  messages: int,
  bytes: int,
  createdBy: string,
  createdAt: datetime
}

type TenantView = { tenant: Tenant, role: string }

type TicketView = {
  ticket: Ticket,
  messages: list<Message>,
  attachments: list<Attachment>
}

type AttachmentFile = { name: string, content: string, bytes: int }

type ExportFile = { key: string, content: string, bytes: int }

type Stats = {
  tickets: int,
  open: int,
  pending: int,
  resolved: int,
  breached: int,
  unassigned: int,
  members: int
}

type SweepResult = { breached: int }

error Unauthorized
error Invalid
error Conflict
error NotFound
error Forbidden

service Desk : http {
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
    unique Tenant.slug
    unique Member.(tenantId, userId)
  }

  contract {
    // ---- tenants and membership -------------------------------------------

    auth op createTenant(name: string, slug: string, inviteCode: string) -> TenantView {
      route: "POST /v1/tenants"
      effects: store.find, store.insert, auth.actor, uuid.new
      errors: Unauthorized, Invalid, Conflict
      on error Unauthorized: name != null
      post: result.tenant.id != null
      on error Invalid: name != null
      on error Conflict: slug != null
    }

    // Joining is idempotent: a second join with the same code returns the
    // existing membership instead of a duplicate row.
    auth op join(tenantId: string, inviteCode: string) -> Member {
      route: "POST /v1/tenants/:tenantId/join"
      effects: store.fetch, store.find, store.insert, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Conflict
      on error Unauthorized: tenantId != null
      post: result.id != null
      on error NotFound: tenantId != null
      on error Forbidden: inviteCode != null
      on error Conflict: tenantId != null
    }

    // Only an owner may hand out staff rights. A member cannot promote himself.
    auth op promote(tenantId: string, userId: string, role: string) -> Member {
      route: "POST /v1/tenants/:tenantId/promote"
      effects: store.find, store.update, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid
      on error Unauthorized: tenantId != null
      post: result.id != null
      on error NotFound: tenantId != null
      on error Forbidden: userId != null
      on error Invalid: role != null
    }

    auth op myTenants() -> list<TenantView> {
      route: "GET /v1/tenants"
      effects: store.find, store.fetch, auth.actor
      errors: Unauthorized
      on error Unauthorized: result != null
      post: result != null
    }

    // ---- tickets ----------------------------------------------------------

    // Priority is derived from the text at creation, SLA from it: high 4h,
    // normal 24h, low 72h. The triage consumer assigns the least loaded agent;
    // the response does not wait for it.
    auth op createTicket(tenantId: string, subject: string, body: string) -> Ticket {
      route: "POST /v1/tenants/:tenantId/tickets"
      effects: store.find, store.insert, store.count, events.publish, auth.actor, uuid.new
      errors: Unauthorized, Invalid, NotFound, Forbidden, Conflict
      on error Unauthorized: tenantId != null
      post: result.id != null
      on error Invalid: subject != null
      on error NotFound: tenantId != null
      on error Forbidden: tenantId != null
      on error Conflict: subject != null
    }

    auth op listTickets(tenantId: string, status: string = "all", limit: int = 50) -> list<Ticket> {
      route: "GET /v1/tenants/:tenantId/tickets"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: tenantId != null
      post: result != null
      on error Forbidden: tenantId != null
    }

    auth op ticket(ticketId: string) -> TicketView {
      route: "GET /v1/tickets/:ticketId"
      effects: store.fetch, store.find, auth.actor
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: ticketId != null
      post: result.ticket.id != null
      on error NotFound: ticketId != null
      on error Forbidden: ticketId != null
    }

    // A requester reply on a resolved ticket reopens it; a staff reply never
    // does. Every reply queues a notify event for the other side.
    auth op reply(ticketId: string, body: string, internal: bool = false) -> Message {
      route: "POST /v1/tickets/:ticketId/messages"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: ticketId != null
      post: result.id != null
      on error NotFound: ticketId != null
      on error Forbidden: ticketId != null
      on error Invalid: body != null
      on error Conflict: ticketId != null
    }

    // Assignment is limited to tenant staff; the assignee must be a member
    // with the agent or owner role.
    auth op assign(ticketId: string, assignee: string) -> Ticket {
      route: "POST /v1/tickets/:ticketId/assign"
      effects: store.fetch, store.find, store.insert, store.update, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid, Conflict
      on error Unauthorized: ticketId != null
      post: result.id != null
      on error NotFound: ticketId != null
      on error Forbidden: assignee != null
      on error Invalid: assignee != null
      on error Conflict: ticketId != null
    }

    auth op resolve(ticketId: string) -> Ticket {
      route: "POST /v1/tickets/:ticketId/resolve"
      effects: store.fetch, store.find, store.insert, store.update, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Conflict
      on error Unauthorized: ticketId != null
      post: result.id != null
      on error NotFound: ticketId != null
      on error Forbidden: ticketId != null
      on error Conflict: ticketId != null
    }

    // Attachments are text: io.blobPut takes a string in this build (#48), so
    // the example stores text evidence, not arbitrary binary.
    auth op attach(ticketId: string, name: string, content: string) -> Attachment {
      route: "POST /v1/tickets/:ticketId/attachments"
      effects: store.fetch, store.update, store.insert, files.put, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden, Invalid
      on error Unauthorized: ticketId != null
      post: result.id != null
      on error NotFound: ticketId != null
      on error Forbidden: ticketId != null
      on error Invalid: name != null
    }

    auth op attachment(ticketId: string, attachmentId: string) -> AttachmentFile {
      route: "GET /v1/tickets/:ticketId/attachments/:attachmentId"
      effects: store.fetch, files.get, auth.actor
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: ticketId != null
      post: result.name != null
      on error NotFound: attachmentId != null
      on error Forbidden: ticketId != null
    }

    // ---- export -----------------------------------------------------------

    // The export is a background job: the row comes back queued, the consumer
    // writes JSONL to S3 and flips it to ready.
    auth op exportTenant(tenantId: string) -> Export {
      route: "POST /v1/tenants/:tenantId/export"
      effects: store.find, store.insert, events.publish, auth.actor, uuid.new
      errors: Unauthorized, NotFound, Forbidden
      on error Unauthorized: tenantId != null
      post: result.id != null
      on error NotFound: tenantId != null
      on error Forbidden: tenantId != null
    }

    auth op listExports(tenantId: string) -> list<Export> {
      route: "GET /v1/tenants/:tenantId/exports"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: tenantId != null
      post: result != null
      on error Forbidden: tenantId != null
    }

    auth op downloadExport(tenantId: string, exportId: string) -> ExportFile {
      route: "GET /v1/tenants/:tenantId/exports/:exportId"
      effects: store.fetch, files.get, auth.actor
      errors: Unauthorized, NotFound, Forbidden, Conflict
      on error Unauthorized: tenantId != null
      post: result.key != null
      on error NotFound: exportId != null
      on error Forbidden: tenantId != null
      on error Conflict: exportId != null
    }

    // ---- notifications and ops --------------------------------------------

    auth op notifications(unread: bool = false) -> list<Notification> {
      route: "GET /v1/notifications"
      effects: store.find, auth.actor
      errors: Unauthorized
      on error Unauthorized: unread != null
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

    auth op stats(tenantId: string) -> Stats {
      route: "GET /v1/tenants/:tenantId/stats"
      effects: store.count, store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: tenantId != null
      post: result.tickets >= 0
      on error Forbidden: tenantId != null
    }

    auth op auditTrail(tenantId: string, limit: int = 50) -> list<Audit> {
      route: "GET /v1/tenants/:tenantId/audit"
      effects: store.find, auth.actor
      errors: Unauthorized, Forbidden
      on error Unauthorized: tenantId != null
      post: result != null
      on error Forbidden: tenantId != null
    }

    // SLA sweep, called by an external runner: jobs are queue consumers, not
    // cron tasks (#12). now is explicit so the check is testable.
    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, store.update, store.insert, uuid.new
      errors: none
      post: result.breached >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // Consumer 1: assignment. Picks the staff member with the fewest open
    // tickets and then wakes the notifier.
    job triage(ticketId: string) {
      on: events.triage
      retry: 2
      effects: store.fetch, store.find, store.count, store.update, store.insert, events.publish, uuid.new
      errors: none
    }

    // Consumer 2: one notification per (message, recipient), idempotent by id.
    job notify(ticketId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.find, store.insert, uuid.new
      errors: none
    }

    // Consumer 3: JSONL transcript of the tenant into S3.
    job exportRun(exportId: string) {
      on: events.exportRun
      retry: 2
      effects: store.fetch, store.find, store.update, files.put
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
