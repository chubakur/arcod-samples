module delivery_zones @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-25"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.kv @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type ZoneId = uuid
type QuoteId = uuid

// A delivery zone is a polygon in GeoJSON-ish form: [[lng, lat], ...].
// The polygon travels as text because the language has no geo type yet.
type Zone = {
  id: ZoneId,
  name: string,
  polygon: string,
  basePrice: int,
  perKm: int,
  active: boolean,
  reindexedAt: datetime?,
  createdAt: datetime
}

type ZoneInput = {
  name: string,
  polygon: string,
  basePrice: int,
  perKm: int
}

type Quote = {
  id: QuoteId,
  zoneId: string,
  lat: decimal,
  lng: decimal,
  distanceKm: decimal,
  price: int,
  address: string,
  cachedZone: boolean,
  createdAt: datetime
}

type QuoteInput = {
  lat: decimal,
  lng: decimal,
  distanceKm: decimal
}

type Snapshot = {
  key: string,
  content: string
}

type Stats = {
  zones: int,
  quotes: int,
  activeZones: int
}

type GeoPoint = {
  lat: decimal,
  lng: decimal
}

type GeoAddress = {
  label: string
}

// Somebody else's geocoder. We own the payload, the environment owns the
// address. Reverse geocoding is enriched into every quote.
external service Geocoder : http {
  contract {
    op reverse(point: GeoPoint) -> GeoAddress {
      route: "POST /v1/reverse"
    }
  }
}

error Invalid
error NotFound
error Conflict
error Unavailable

service DeliveryZones : http {
  uses store: sql(ttl: 31536000s)
  uses zoneCache: kv(ttl: 3600s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, zoneCache.get, zoneCache.set, events.publish, files.put, files.get, uuid.new, Geocoder.reverse
    deny net, fs, exec
  }

  rules {
    unique Zone.name
  }

  contract {
    public op addZone(name: string, polygon: string, basePrice: int, perKm: int) -> Zone {
      route: "POST /v1/zones"
      effects: store.find, store.insert, events.publish, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op zones() -> list<Zone> {
      route: "GET /v1/zones"
      effects: store.find
      errors: none
      post: result != null
    }

    public op quote(lat: decimal, lng: decimal, distanceKm: decimal) -> Quote {
      route: "POST /v1/quotes"
      effects: store.find, store.insert, zoneCache.get, zoneCache.set, uuid.new, Geocoder.reverse
      errors: Invalid, NotFound, Unavailable
      post: result != null
      on error Invalid: lat != null
      on error NotFound: lat != null
      on error Unavailable: lat != null
    }

    public op getQuote(id: QuoteId) -> Quote {
      route: "GET /v1/quotes/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op snapshot(id: ZoneId) -> Snapshot {
      route: "GET /v1/zones/:id/snapshot"
      effects: store.fetch, files.get
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result != null
    }

    // The consumer side: a zone change is durable in SQL, the snapshot in S3
    // and the reindex timestamp are written by the job, not by the request.
    job reindex(zoneId: ZoneId) {
      on: events.reindex
      retry: 2
      effects: store.fetch, store.update, files.put
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "redis", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Geocoder -> endpoint(url: "http://localhost:9096")
  deploy docker
}
