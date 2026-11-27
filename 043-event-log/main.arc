module event_log @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.kv @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

// One stream per order aggregate. `version` is the last accepted seq and the
// only thing an append is allowed to compare against.
type Stream = {
  id: string,
  name: string,
  version: int,
  eventCount: int,
  createdAt: datetime,
  updatedAt: datetime
}

// The log itself: append-only, never updated, never deleted. `seq` is dense per
// stream and (streamId, seq) is unique, so a racing append loses on the index
// instead of silently overwriting history.
type Event = {
  id: string,
  streamId: string,
  seq: int,
  type: string,
  payload: string,
  actor: string,
  recordedAt: datetime
}

// Read model. Rebuilt from the log by the projector; nothing writes it from
// the HTTP side.
type OrderView = {
  id: string,
  status: string,
  total: int,
  lines: int,
  lastSeq: int,
  updatedAt: datetime
}

// Consumer progress in kv: what a human looks at when a projection lags.
type Checkpoint = {
  id: string,
  name: string,
  streamId: string,
  seq: int,
  lastEventId: string,
  updatedAt: datetime
}

// One row per packed log segment in S3.
type Archive = {
  id: string,
  streamId: string,
  key: string,
  events: int,
  bytes: int,
  createdAt: datetime
}

type Export = {
  key: string,
  events: int,
  bytes: int,
  content: string
}

type Stats = {
  streams: int,
  events: int,
  views: int,
  archives: int
}

type Ack = {
  queued: bool,
  topic: string,
  subject: string
}

error Invalid
error Conflict
error NotFound

service Ledger : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses archive: blob
  uses cursor: kv(ttl: 2592000s)
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.remove, store.find, store.count, events.publish, archive.put, archive.get, cursor.get, cursor.set, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Stream.name
    unique Event.(streamId, seq)
  }

  contract {
    // Creating a stream twice with the same name answers with the first one:
    // a client that retried after a timeout must not fork the log.
    public op createStream(name: string) -> Stream {
      route: "POST /v1/streams"
      effects: store.find, store.insert, store.fetch, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op stream(streamId: string) -> Stream {
      route: "GET /v1/streams/:streamId"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: streamId != null
    }

    // Append is a compare-and-set on stream.version. A stale expectedVersion
    // is a 409 and nothing is written; the client re-reads and retries.
    public op append(streamId: string, type: string, payload: string, expectedVersion: int) -> Event {
      route: "POST /v1/streams/:streamId/events"
      effects: store.fetch, store.update, store.insert, events.publish, uuid.new
      errors: Invalid, Conflict, NotFound
      post: result != null
      on error Invalid: type != null
      on error Conflict: expectedVersion != null
      on error NotFound: streamId != null
    }

    public op events(streamId: string, limit: int) -> list<Event> {
      route: "GET /v1/streams/:streamId/events"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    // The projection is served from SQL and carries the seq it has consumed,
    // so a stale read is visible instead of guessed.
    public op order(streamId: string) -> OrderView {
      route: "GET /v1/orders/:streamId"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: streamId != null
    }

    public op projections() -> list<Checkpoint> {
      route: "GET /v1/projections"
      effects: store.find
      errors: none
      post: result != null
    }

    // Drop the view and fold the log again. The only recovery path when a
    // projection body changes; the log is the source of truth.
    public op replay(streamId: string) -> Ack {
      route: "POST /v1/streams/:streamId/replay"
      effects: store.fetch, events.publish
      errors: NotFound
      post: result != null
      on error NotFound: streamId != null
    }

    public op archiveStream(streamId: string) -> Ack {
      route: "POST /v1/streams/:streamId/archive"
      effects: store.fetch, events.publish
      errors: NotFound
      post: result != null
      on error NotFound: streamId != null
    }

    public op exportArchive(streamId: string) -> Export {
      route: "GET /v1/streams/:streamId/archive"
      effects: store.find, store.fetch, archive.get
      errors: NotFound
      post: result != null
      on error NotFound: streamId != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result != null
    }

    // Consumer 1: one event at a time, idempotent by seq.
    job project(eventId: string) {
      on: events.project
      retry: 3
      effects: store.fetch, store.insert, store.update, store.find, cursor.set, cursor.get
      errors: none
    }

    // Consumer 2: rebuild one aggregate from the log.
    job rebuild(streamId: string) {
      on: events.rebuild
      retry: 2
      effects: store.find, store.fetch, store.remove, store.insert, store.update, cursor.set
      errors: none
    }

    // Consumer 3: pack the log into S3 as JSONL, then record the object.
    job pack(streamId: string) {
      on: events.archive
      retry: 2
      effects: store.find, store.fetch, store.insert, archive.put, cursor.set
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind archive -> s3(host: "s3", port: 9000)
  bind uuid -> local
  deploy docker
}
