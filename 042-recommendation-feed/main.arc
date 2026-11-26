module recommendation_feed @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-26"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.kv @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type ItemId = uuid
type EventId = uuid

// Catalogue rows are the only place a title lives: feed entries carry the id
// and are joined with the catalogue at read time.
type Item = {
  id: ItemId,
  title: string,
  category: string,
  price: int,
  active: boolean,
  createdAt: datetime
}

// One interaction, already weighted by kind (view=1, cart=2, buy=3).
// clientEventId is the producer's idempotency key.
type Interaction = {
  id: EventId,
  clientEventId: string,
  userId: string,
  itemId: ItemId,
  kind: string,
  weight: int,
  ts: datetime
}

// One user's evidence about one pair. The id is "user|min|max", so a user can
// only ever contribute one boost per pair and a retried job cannot inflate it.
// Pair counts are derived from these rows at snapshot time: nothing does a
// read-modify-write on a shared counter (chubakur/arcod#10).
type Touch = {
  id: string,
  userId: string,
  pairId: string,
  a: ItemId,
  b: ItemId,
  boost: int,
  updatedAt: datetime
}

// A model version is a durable row per built snapshot. The pointer in kv is
// what readers use; this row is the audit trail.
type ModelVersion = {
  id: string,
  version: int,
  key: string,
  items: int,
  pairs: int,
  builtAt: datetime
}

type Model = {
  version: int,
  key: string,
  items: int,
  pairs: int,
  builtAt: string
}

type FeedEntry = {
  itemId: string,
  title: string,
  score: int,
  reason: string
}

type Snapshot = {
  key: string,
  version: int,
  bytes: int,
  content: string
}

type Stats = {
  items: int,
  events: int,
  touches: int,
  modelVersion: int
}

error Invalid
error Conflict
error NotFound

service Recommend : http {
  uses store: sql(ttl: 31536000s)
  uses pointer: kv(ttl: 86400s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, pointer.get, pointer.set, events.publish, files.put, files.get, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Item.title
    unique Interaction.clientEventId
    unique Touch.id
  }

  contract {
    public op addItem(title: string, category: string, price: int) -> Item {
      route: "POST /v1/items"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: title != null
      on error Conflict: title != null
    }

    public op items() -> list<Item> {
      route: "GET /v1/items"
      effects: store.find
      errors: none
      post: result != null
    }

    // Ingest one interaction. A repeated clientEventId answers with the row
    // that already exists instead of publishing a second recompute.
    public op track(clientEventId: string, userId: string, itemId: string, kind: string) -> Interaction {
      route: "POST /v1/events"
      effects: store.find, store.fetch, store.insert, events.publish
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: kind != null
      on error Conflict: clientEventId != null
    }

    public op feed(userId: string, limit: int) -> list<FeedEntry> {
      route: "GET /v1/feed/:userId"
      effects: store.find, pointer.get, files.get
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    // Manual rebuild trigger. The job is the only writer of a model version.
    public op rebuildModel() -> Model {
      route: "POST /v1/model/rebuild"
      effects: events.publish, pointer.get, store.find
      errors: none
      post: result != null
    }

    public op model() -> Model {
      route: "GET /v1/model"
      effects: pointer.get
      errors: none
      post: result != null
    }

    public op modelSnapshot() -> Snapshot {
      route: "GET /v1/model/snapshot"
      effects: pointer.get, files.get
      errors: NotFound
      post: result != null
      on error NotFound: limit != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, pointer.get
      errors: none
      post: result != null
    }

    // Consumer 1: one user's touched items become Touch rows (one per pair).
    // The job is idempotent: a retry rewrites the same boost.
    job recompute(userId: string) {
      on: events.recompute
      retry: 2
      effects: store.find, store.insert, store.update
      errors: none
    }

    // Consumer 2: fold Touch rows into a versioned snapshot in S3 and flip the
    // pointer. Readers never see a half-written model.
    job snapshot(reason: string) {
      on: events.snapshot
      retry: 2
      effects: store.find, store.insert, store.update, files.put, pointer.get, pointer.set
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "redis", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  deploy docker
}
