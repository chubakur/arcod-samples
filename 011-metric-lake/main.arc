module metric_lake @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type BatchId = uuid
type ExportId = uuid
type Stamp = string

// One raw measurement. Points live in the hot store under a short TTL and are
// folded into minute buckets by the consumer.
type Sample = {
  ts: datetime,
  value: float
}

// A client batch. (metric, idem) is the idempotency key.
type Batch = {
  id: BatchId,
  metric: string,
  idem: string,
  cnt: int,
  status: string,
  first: datetime,
  last: datetime,
  receivedAt: datetime
}

type Point = {
  id: uuid,
  metric: string,
  batch: BatchId,
  slot: Stamp,
  ts: datetime,
  value: float
}

type Bucket = {
  id: uuid,
  metric: string,
  slot: Stamp,
  cnt: int,
  total: float,
  lo: float,
  hi: float,
  updatedAt: datetime
}

type Monitor = {
  id: uuid,
  metric: string,
  threshold: float,
  updatedAt: datetime
}

type Alert = {
  id: uuid,
  metric: string,
  slot: Stamp,
  hi: float,
  threshold: float,
  sentAt: datetime
}

type AlertAck = { ok: boolean, ref: string }

type ExportRec = {
  id: ExportId,
  metric: string,
  from: Stamp,
  to: Stamp,
  objectKey: string,
  lines: int,
  bytes: int,
  createdAt: datetime
}

type ExportBundle = { rec: ExportRec, body: string }

type Receipt = {
  batchId: BatchId,
  accepted: int,
  duplicate: bool,
  first: datetime,
  last: datetime
}

type SeriesPoint = {
  slot: Stamp,
  cnt: int,
  total: float,
  lo: float,
  hi: float,
  mean: float
}

type Series = {
  metric: string,
  from: Stamp,
  to: Stamp,
  step: int,
  points: list<SeriesPoint>,
  missing: int,
  total: int
}

type Sweep = {
  horizonHours: int,
  cutoff: Stamp,
  points: int,
  buckets: int,
  report: string,
  at: datetime
}

// Somebody else's alerting endpoint: we know the address and the payload only.
external service Alerter : http {
  contract {
    op notify(alert: Alert) -> AlertAck {
      route: "POST /v1/alerts"
    }
  }
}

error Invalid
error NotFound
error Conflict

service MetricLake : http {
  uses store: sql(ttl: 2592000s)
  uses events: queue
  uses archive: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.remove, uuid.new, events.publish, archive.put, archive.get, Alerter.notify
    deny net, fs, exec
  }

  rules {
    unique Batch.(metric, idem)
    unique Bucket.(metric, slot)
    unique Monitor.metric
  }

  contract {
    public op ingest(metric: string, idem: string, samples: list<Sample>) -> Receipt {
      route: "POST /v1/metrics/:metric/points"
      effects: store.find, store.insert, uuid.new, events.publish
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: metric != null
      on error Conflict: metric != null
    }

    public op series(metric: string, from: Stamp, to: Stamp, step: int = 60) -> Series {
      route: "GET /v1/metrics/:metric/series"
      effects: store.find
      errors: Invalid, NotFound
      post: result != null
      on error Invalid: metric != null
      on error NotFound: metric != null
    }

    public op setMonitor(metric: string, threshold: float) -> Monitor {
      route: "PUT /v1/metrics/:metric/monitor"
      effects: store.find, store.insert, store.update, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: metric != null
      on error Conflict: metric != null
    }

    public op publishExport(metric: string, from: Stamp, to: Stamp) -> ExportRec {
      route: "POST /v1/metrics/:metric/export"
      effects: store.find, store.insert, archive.put, uuid.new
      errors: Invalid, NotFound
      post: result != null
      on error Invalid: metric != null
      on error NotFound: metric != null
    }

    public op getExport(id: ExportId) -> ExportBundle {
      route: "GET /v1/exports/:id"
      effects: store.fetch, archive.get
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op sweep(horizonHours: int = 24) -> Sweep {
      route: "POST /v1/admin/sweep"
      effects: store.find, store.remove, archive.put
      errors: Invalid
      post: result != null
      on error Invalid: horizonHours != null
    }

    public op stats(metric: string) -> Series {
      route: "GET /v1/metrics/:metric/stats"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: metric != null
    }

    // The consumer: folds one accepted batch into minute buckets, then raises an
    // alert through the external service when a bucket crosses its monitor.
    job rollup(batchId: BatchId) {
      on: events.rollup
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, uuid.new, Alerter.notify
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind archive -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Alerter -> endpoint(url: "http://localhost:9099")
  deploy docker
}
