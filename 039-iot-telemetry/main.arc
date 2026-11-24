module iot_telemetry @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-24"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type DeviceId = uuid
type RuleId = uuid
type AlertId = uuid
type ReportId = uuid

type Device = {
  id: DeviceId,
  name: string,
  site: string,
  kind: string,
  status: string,
  lastSeenAt: datetime?,
  createdAt: datetime
}

// One sample from a sensor. A batch carries its own timestamps: the gateway
// may buffer offline and flush later.
type ReadingInput = {
  metric: string,
  value: decimal,
  at: datetime
}

type Reading = {
  id: uuid,
  deviceId: string,
  metric: string,
  value: decimal,
  at: datetime,
  receivedAt: datetime
}

type RuleInput = {
  deviceId: string = "*",
  metric: string,
  op: string,
  threshold: decimal,
  cooldownSec: int = 300,
  severity: string = "warning"
}

type Rule = {
  id: RuleId,
  deviceId: string,
  metric: string,
  op: string,
  threshold: decimal,
  cooldownSec: int,
  severity: string,
  active: boolean,
  lastAlertAt: datetime?,
  createdAt: datetime
}

type Alert = {
  id: AlertId,
  ruleId: string,
  deviceId: string,
  metric: string,
  value: decimal,
  severity: string,
  status: string,
  openedAt: datetime,
  notifiedAt: datetime?,
  ackedAt: datetime?,
  resolvedAt: datetime?,
  note: string?
}

type AlertPage = { items: list<Alert>, total: int }
type IngestResult = { accepted: int, deviceId: string, lastSeenAt: datetime }
type Stats = { devices: int, readings: int, rules: int, openAlerts: int }
type DeadPage = { items: list<string> }
type DeadDrop = { dropped: bool }

type Report = {
  id: ReportId,
  key: string,
  status: string,
  readings: int,
  devices: int,
  createdAt: datetime,
  doneAt: datetime?
}

type ReportFile = { key: string, content: string }

// The pager is somebody else's service: the model names the payload, the
// environment owns the address.
type NotifyPayload = {
  alertId: string,
  deviceId: string,
  metric: string,
  value: string,
  severity: string
}
type NotifyReply = { delivered: boolean, ticket: string? }

external service Pager : http {
  contract {
    op notify(payload: NotifyPayload) -> NotifyReply {
      route: "POST /v1/notify"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Telemetry : http {
  uses store: sql(ttl: 31536000s, consistency: strong)
  uses readings: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, readings.publish, readings.dead, readings.drop, files.put, files.get, uuid.new, Pager.notify
  }

  contract {
    public op addDevice(name: string, site: string, kind: string) -> Device {
      route: "POST /v1/devices"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op devices() -> list<Device> {
      route: "GET /v1/devices"
      effects: store.find
      errors: none
      post: result != null
    }

    // The device row is updated before anything is queued: a lost message
    // must not lose the reading.
    public op ingest(id: DeviceId, samples: list<ReadingInput>) -> IngestResult {
      route: "POST /v1/devices/:id/readings"
      effects: store.fetch, store.insert, store.update, readings.publish, uuid.new
      errors: Invalid, NotFound
      post: result.accepted >= 0
      on error Invalid: samples != null
      on error NotFound: id != null
    }

    public op readings(id: DeviceId, metric: string, limit: int = 50) -> list<Reading> {
      route: "GET /v1/devices/:id/readings"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op addRule(rule: RuleInput) -> Rule {
      route: "POST /v1/rules"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: rule != null
    }

    public op rules() -> list<Rule> {
      route: "GET /v1/rules"
      effects: store.find
      errors: none
      post: result != null
    }

    public op alerts(status: string = "open", limit: int = 50) -> AlertPage {
      route: "GET /v1/alerts"
      effects: store.find, store.count
      errors: none
      post: result.total >= 0
    }

    public op ack(id: AlertId) -> Alert {
      route: "POST /v1/alerts/:id/ack"
      status: 200
      effects: store.fetch, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op resolve(id: AlertId) -> Alert {
      route: "POST /v1/alerts/:id/resolve"
      status: 200
      effects: store.fetch, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // A daily rollup is built off the request path: the operator gets an id
    // and polls, the job writes the CSV to object storage.
    public op createReport() -> Report {
      route: "POST /v1/reports"
      effects: store.insert, readings.publish, uuid.new
      errors: none
      post: result.id != null
    }

    public op report(id: ReportId) -> Report {
      route: "GET /v1/reports/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    public op reportFile(id: ReportId) -> ReportFile {
      route: "GET /v1/reports/:id/file"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result.devices >= 0
    }

    public op dead() -> DeadPage {
      route: "GET /v1/dead"
      effects: readings.dead
      errors: none
      post: result.items != null
    }

    // Replaying is explicit: the operator names the payload that was already
    // handled, so the dead list does not grow forever.
    public op dropDead(payload: string) -> DeadDrop {
      route: "POST /v1/dead/drop"
      status: 200
      effects: readings.drop
      errors: none
      post: result.dropped != null
    }

    // One evaluation per sample. Rules are rows, not code: the job compares
    // and either opens an alert or stays quiet inside the cooldown.
    job evaluate(deviceId: string, metric: string, value: decimal, at: string) {
      on: readings.samples
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, uuid.new, Pager.notify
      errors: none
    }

    job buildReport(reportId: string) {
      on: readings.reports
      retry: 1
      effects: store.fetch, store.find, store.update, files.put
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind readings -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Pager -> endpoint(url: "http://host.docker.internal:9096")
  deploy docker
}
