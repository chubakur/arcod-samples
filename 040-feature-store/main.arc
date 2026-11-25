module feature_store @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-25"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.kv @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type Feature = {
  id: uuid,
  name: string,
  dtype: string,
  version: int,
  description: string,
  ttlSeconds: int,
  status: string,
  createdAt: datetime,
  updatedAt: datetime
}

// One observation. The row is the durable record; object storage keeps the
// offline copy and the queue carries the materialisation order.
type Event = {
  id: uuid,
  feature: string,
  entityId: string,
  value: string,
  at: datetime,
  ingestedAt: datetime,
  version: int,
  materialized: bool,
  offKey: string?
}

type Export = {
  id: uuid,
  status: string,
  features: list<string>,
  fromAt: datetime,
  toAt: datetime,
  rows: int,
  key: string?,
  error: string?,
  createdAt: datetime,
  finishedAt: datetime?
}

type OnlinePoint = {
  feature: string,
  entityId: string,
  value: string,
  at: datetime,
  version: int,
  ageSeconds: int,
  stale: bool
}

type OfflinePoint = {
  eventId: string,
  feature: string,
  entityId: string,
  value: string,
  at: datetime,
  version: int
}

type ExportFile = { key: string, content: string }
type Stats = {
  features: int,
  events: int,
  pending: int,
  exports: int,
  done: int
}
type DeadPage = { items: list<string> }
type ReplayResult = { replayed: int, left: int }

type ProfileQuery = { entityId: string }
type Profile = { entityId: string, segment: string, country: string, plan: string }

// The attribute service is somebody else's system: the model names the payload
// and the environment owns the address.
external service Profiles : http {
  contract {
    op lookup(payload: ProfileQuery) -> Profile {
      route: "POST /v1/lookup"
    }
  }
}

error Invalid
error NotFound
error Conflict

service FeatureStore : http {
  uses store: sql(ttl: 31536000s, consistency: strong)
  uses cache: kv(ttl: 86400s, consistency: strong)
  uses bus: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, cache.get, cache.set, bus.publish, bus.dead, bus.drop, files.put, files.get, uuid.new, Profiles.lookup
  }

  contract {
    public op addFeature(name: string, dtype: string, description: string, ttlSeconds: int) -> Feature {
      route: "POST /v1/features"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op features() -> list<Feature> {
      route: "GET /v1/features"
      effects: store.find
      errors: none
      post: result != null
    }

    // A new version does not rewrite history: old events keep the version they
    // were recorded with, new ones get this one.
    public op publishVersion(name: string, description: string) -> Feature {
      route: "POST /v1/features/:name/versions"
      effects: store.find, store.update
      errors: NotFound
      post: result.version > 0
      on error NotFound: name != null
    }

    public op record(feature: string, entityId: string, value: string, at: string) -> Event {
      route: "POST /v1/events"
      effects: store.find, store.insert, bus.publish, uuid.new
      errors: Invalid, NotFound
      post: result.id != null
      on error Invalid: value != null
      on error NotFound: feature != null
    }

    public op online(feature: string, entityId: string) -> OnlinePoint {
      route: "GET /v1/online/:feature/:entityId"
      effects: store.find, cache.get
      errors: NotFound
      post: result.entityId != null
      on error NotFound: entityId != null
    }

    public op offline(feature: string, entityId: string) -> list<OfflinePoint> {
      route: "GET /v1/offline/:feature/:entityId"
      effects: store.find
      errors: none
      post: result != null
    }

    public op createExport(features: list<string>, fromAt: string, toAt: string) -> Export {
      route: "POST /v1/exports"
      effects: store.find, store.insert, bus.publish, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: features != null
    }

    public op exportJob(id: string) -> Export {
      route: "GET /v1/exports/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    public op exportFile(id: string) -> ExportFile {
      route: "GET /v1/exports/:id/file"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result.features >= 0
    }

    public op dead() -> DeadPage {
      route: "GET /v1/dead"
      effects: bus.dead
      errors: none
      post: result.items != null
    }

    public op replayDead() -> ReplayResult {
      route: "POST /v1/dead/replay"
      status: 200
      effects: bus.dead, bus.drop, bus.publish
      errors: none
      post: result.replayed >= 0
    }

    // One row per observation. The job writes the offline object first and the
    // online value second, so a crash leaves an offline gap, never a lie in
    // the cache.
    job materialize(eventId: string) {
      on: bus.events
      retry: 2
      effects: store.fetch, store.update, cache.set, files.put
      errors: none
    }

    // Point-in-time export: for every entity the last value at or before the
    // window end, enriched with attributes from the profile service.
    job buildExport(exportId: string) {
      on: bus.exports
      retry: 1
      effects: store.fetch, store.find, store.update, files.put, Profiles.lookup
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  // No bind for `cache`: with a sql store the kv alias lives in the sql
  // store's arcod_kv table (A094).
  bind bus -> redis(host: "redis", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Profiles -> endpoint(url: "http://host.docker.internal:9098")
  deploy docker
}
