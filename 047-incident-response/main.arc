module incident_response @0.1.0 {
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

// A monitored service. The runbook is a short text link kept next to the tier:
// responders need it before the first alert, not after the postmortem.
type Service = {
  id: string,
  name: string,
  tier: string,
  runbook: string,
  createdAt: datetime
}

// A shift is the only source of truth about who is on call. Overlaps are
// rejected by the create operation, so a lookup can never see two agents.
type Shift = {
  id: string,
  serviceId: string,
  agent: string,
  startsAt: datetime,
  endsAt: datetime
}

// One alert fingerprint plus one open incident. dedupCount is the number of
// alerts folded into the incident while the dedup key was alive.
type Incident = {
  id: string,
  serviceId: string,
  title: string,
  fingerprint: string,
  severity: string,
  status: string,
  assignee: string,
  dedupCount: int,
  openedAt: datetime,
  ackedAt: datetime?,
  resolvedAt: datetime?,
  summary: string,
  postmortemKey: string,
  escalated: bool
}

type IncidentEvent = {
  id: string,
  incidentId: string,
  kind: string,
  actor: string,
  detail: string,
  at: datetime
}

type AlertResult = {
  incidentId: string,
  deduped: bool,
  status: string,
  assignee: string,
  dedupCount: int
}

type OnCall = {
  serviceId: string,
  agent: string,
  shiftId: string,
  until: datetime?
}

type IncidentView = {
  incident: Incident,
  events: list<IncidentEvent>
}

type Stats = {
  services: int,
  open: int,
  acked: int,
  resolved: int,
  deduped: int,
  mttaSeconds: int
}

type Postmortem = {
  key: string,
  content: string,
  bytes: int
}

type SweepResult = {
  breached: int,
  escalated: int
}

error Invalid
error Conflict
error NotFound

service Incidents : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses live: stream
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.remove, store.find, store.count, events.publish, events.dead, live.publish, files.put, files.get, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Service.name
  }

  contract {
    // ---- services and on-call ---------------------------------------------

    public op createService(name: string, tier: string = "T2", runbook: string = "") -> Service {
      route: "POST /v1/services"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    // A shift that overlaps an existing one is 409: two responders on call for
    // the same service would make every assignment a coin toss.
    public op createShift(serviceId: string, agent: string, startsAt: datetime, endsAt: datetime) -> Shift {
      route: "POST /v1/services/:serviceId/shifts"
      effects: store.fetch, store.find, store.insert, uuid.new
      errors: NotFound, Invalid, Conflict
      post: result.id != null
      on error NotFound: serviceId != null
      on error Invalid: startsAt != null
      on error Conflict: startsAt != null
    }

    // at is optional: without it the operation answers for "now".
    public op onCall(serviceId: string, at: datetime?) -> OnCall {
      route: "GET /v1/services/:serviceId/on-call"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.serviceId != null
      on error NotFound: serviceId != null
    }

    // ---- alerts ------------------------------------------------------------

    // The fast path: one kv lookup decides dedup, one SQL insert opens the
    // incident, one queue message wakes the notifier. No external calls here.
    public op ingestAlert(serviceId: string, fingerprint: string, title: string, severity: string = "SEV2", observedAt: datetime?) -> AlertResult {
      route: "POST /v1/alerts"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, uuid.new
      errors: NotFound, Invalid
      post: result.incidentId != null
      on error NotFound: serviceId != null
      on error Invalid: title != null
    }

    // ---- incidents ---------------------------------------------------------

    public op listIncidents(status: string = "open", limit: int = 20) -> list<Incident> {
      route: "GET /v1/incidents"
      effects: store.find
      errors: none
      post: result != null
    }

    public op incident(id: string) -> IncidentView {
      route: "GET /v1/incidents/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.incident.id != null
      on error NotFound: id != null
    }

    // Acknowledging an acknowledged incident is a no-op: pager retries are
    // normal and must not be a 409. Resolving twice is a conflict.
    public op ack(id: string, actor: string = "responder") -> Incident {
      route: "POST /v1/incidents/:id/ack"
      effects: store.fetch, store.update, store.insert, live.publish, uuid.new
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // Resolving publishes the postmortem job; the response does not wait for
    // S3. A redelivery sees postmortemKey and does no second write.
    public op resolve(id: string, actor: string = "responder", summary: string = "") -> Incident {
      route: "POST /v1/incidents/:id/resolve"
      effects: store.fetch, store.update, store.insert, events.publish, live.publish, uuid.new
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // SLA breach sweep. Called by the external runner (a cron is not a job);
    // it re-notifies open incidents that nobody acknowledged in time.
    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, store.update, store.insert, events.publish, uuid.new
      errors: none
      post: result.breached >= 0
    }

    public op postmortem(id: string) -> Postmortem {
      route: "GET /v1/incidents/:id/postmortem"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result.services >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // Consumer 1: assignment and fan-out. The queue message carries the id;
    // the incident row stays the source of truth.
    job notify(incidentId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, live.publish, uuid.new
      errors: none
    }

    // Consumer 2: renders the timeline into markdown and stores it in S3.
    job postmortemDoc(incidentId: string) {
      on: events.postmortem
      retry: 2
      effects: store.fetch, store.find, files.put, store.update, uuid.new
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
  deploy docker
}
