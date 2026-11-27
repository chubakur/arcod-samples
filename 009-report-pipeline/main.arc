module report_pipeline @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.ids @1
use capability arcod.std.blob @1
use capability arcod.std.queue @1

type ReportId = uuid
type Status = string
type Contents = bytes(min: 1, max: 256kb)
type Report = {
  id: ReportId,
  name: string,
  status: Status,
  size: int,
  lines: int,
  words: int,
  createdAt: datetime,
  doneAt: datetime?
}

error Invalid
error NotFound
error Conflict

service ReportPipeline : http {
  uses store: sql(ttl: 31536000s, consistency: strong)
  uses uuid: ids
  uses files: blob
  uses events: queue

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.get, store.set, uuid.new, files.put, files.get, events.publish
  }

  contract {
    public op submit(name: string, body: Contents) -> Report {
      route: "POST /v1/reports"
      effects: store.insert, files.put, events.publish, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    public op status(id: ReportId) -> Report {
      route: "GET /v1/reports/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op retry(id: ReportId) -> Report {
      route: "POST /v1/reports/:id/retry"
      effects: store.fetch, store.update, events.publish
      errors: NotFound, Conflict
      post: result != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    job process(reportId: ReportId) {
      on: events.jobs
      retry: 2
      effects: store.fetch, store.update, files.get
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind files -> s3(host: "s3", port: 9000)
  bind events -> redis(host: "queue", port: 6379)
  bind uuid -> local
  deploy docker
}
