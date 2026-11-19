module vector_store @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1

// A vector store with a real (if small) inverted-file index.
//
// The store keeps two generations of truth at once: the vectors themselves
// and the slot assignment produced by the last build. A query uses the slots
// to avoid touching every vector; when the slots cannot answer (collection is
// untrained, nprobe too small, filters kill the candidate set) it falls back
// to a scan and says so in the response. Nothing is hidden behind "approximate
// results": candidates, scanned and probedSlots are part of the payload.

type CollectionInfo = {
  name: string,
  dim: int,
  metric: string,
  nlist: int,
  nprobe: int,
  vectors: int,
  slots: int,
  trained: bool,
  createdAt: datetime
}

// The stored vector. slots is what the index thinks; it can lag behind a
// rebuild, so /index is what makes it true again.
type VectorRec = {
  id: string,
  collection: string,
  vid: string,
  values: list<float>,
  meta: string,
  slots: list<int>,
  version: int,
  updatedAt: datetime
}

// One inverted-file entry: slot -> vector. Written by upsert (when trained)
// and by rebuild. Deleting a vector removes its entries first.
type SlotRec = {
  id: string,
  collection: string,
  slot: int,
  vectorId: string
}

type CentroidRec = {
  id: string,
  collection: string,
  index: int,
  values: list<float>,
  count: int,
  updatedAt: datetime
}

type Collection = {
  id: string,
  name: string,
  dim: int,
  metric: string,
  nlist: int,
  nprobe: int,
  vectors: int,
  slots: int,
  trained: bool,
  createdAt: datetime,
  updatedAt: datetime
}

type VecInput = {
  id: string,
  values: list<float>,
  meta: string,
  text: string
}

type VectorView = {
  id: string,
  collection: string,
  values: list<float>,
  meta: string,
  slots: list<int>,
  version: int,
  updatedAt: datetime
}

type UpsertResult = {
  id: string,
  collection: string,
  version: int,
  slots: list<int>,
  inserted: bool,
  dim: int
}

type BatchResult = {
  inserted: int,
  updated: int,
  slots: int,
  ids: list<string>
}

type Hit = {
  id: string,
  score: float,
  distance: float,
  meta: string,
  values: list<float>
}

type QueryResult = {
  collection: string,
  metric: string,
  k: int,
  probedSlots: list<int>,
  candidates: int,
  scanned: int,
  exact: bool,
  tookMs: int,
  hits: list<Hit>
}

type DeleteVec = {
  id: string,
  collection: string,
  deleted: bool,
  slots: int
}

type DropResult = {
  dropped: bool,
  vectors: int,
  slots: int
}

type RebuildResult = {
  collection: string,
  centroids: int,
  assigned: int,
  slots: int,
  iterations: int,
  tookMs: int
}

type Stats = {
  collection: string,
  dim: int,
  trained: bool,
  vectors: int,
  scannedVectors: int,
  slots: int,
  scannedSlots: int,
  centroids: int
}

type Health = {
  ok: bool,
  collections: int
}

error Invalid
error NotFound
error Conflict

service VectorStore : http {
  uses store: kv(ttl: 604800s)
  uses uuid: ids

  effects {
    allow store.find, store.insert, store.update, store.remove, store.fetch, uuid.new
    deny net, fs, exec
  }

  rules {
    unique VectorRec.(collection, vid)
    unique SlotRec.(collection, slot, vectorId)
    unique CentroidRec.(collection, index)
  }

  contract {
    // Create an empty collection. dim is fixed for life; metric is one of
    // cosine, dot, l2. nlist is the number of inverted-file slots to train.
    public op createCollection(name: string, dim: int, metric: string = "cosine", nlist: int = 8, nprobe: int = 2) -> CollectionInfo {
      route: "POST /v1/collections"
      effects: store.find, store.insert, store.fetch
      errors: Invalid, Conflict
      post: result.name != null
      on error Invalid: dim >= 0
      on error Conflict: name != null
    }

    public op listCollections() -> list<CollectionInfo> {
      route: "GET /v1/collections"
      effects: store.find
      post: result != null
    }

    public op getCollection(name: string) -> CollectionInfo {
      route: "GET /v1/collections/:name"
      effects: store.find, store.fetch
      errors: NotFound
      post: result.name != null
      on error NotFound: name != null
    }

    // Drop the collection, its vectors, slots and centroids. Bounded scan:
    // a demo store with more than 20k rows per collection is out of scope.
    public op dropCollection(name: string) -> DropResult {
      route: "DELETE /v1/collections/:name"
      effects: store.find, store.fetch, store.remove, store.update
      errors: NotFound
      post: result.dropped == true
      on error NotFound: name != null
    }

    // Insert or replace one vector. Either values or text: text is embedded
    // with the deterministic hashing embedder (dim must agree). The slot
    // assignment is recomputed when the collection is trained.
    public op upsertVector(collection: string, id: string, values: list<float> = [], meta: string = "{}", text: string = "") -> UpsertResult {
      route: "POST /v1/vectors"
      effects: store.find, store.fetch, store.insert, store.update, store.remove
      errors: Invalid, NotFound
      post: result.id != null
      on error Invalid: values != null
      on error NotFound: collection != null
    }

    // Batch upsert. All vectors are checked before the first write, so a
    // wrong dimension in the middle does not leave half a batch behind.
    public op upsertBatch(collection: string, vectors: list<VecInput>) -> BatchResult {
      route: "POST /v1/vectors/batch"
      effects: store.find, store.fetch, store.insert, store.update, store.remove
      errors: Invalid, NotFound
      post: result.ids != null
    }

    public op getVector(collection: string, id: string) -> VectorView {
      route: "GET /v1/collections/:collection/vectors/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    public op deleteVector(collection: string, id: string) -> DeleteVec {
      route: "DELETE /v1/collections/:collection/vectors/:id"
      effects: store.find, store.fetch, store.remove, store.update
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    // k nearest neighbours. Either vector or text, not both: text is run
    // through the deterministic hashing embedder. exact=true skips the index
    // and scans the collection; the answer says which path was used.
    public op query(collection: string, vector: list<float> = [], text: string = "", k: int = 5, filter: string = "", nprobe: int = 0, exact: bool = false, includeValues: bool = false) -> QueryResult {
      route: "POST /v1/query"
      effects: store.find, store.fetch
      errors: Invalid, NotFound
      post: result.hits != null
      on error Invalid: k >= 0
      on error NotFound: collection != null
    }

    // Train centroids (k-means, deterministic seeding) and rewrite every
    // slot assignment. This is the only op that makes the index exact again.
    public op rebuild(collection: string) -> RebuildResult {
      route: "POST /v1/index"
      effects: store.find, store.fetch, store.insert, store.update, store.remove
      errors: Invalid, NotFound
      post: result.collection != null
      on error NotFound: collection != null
    }

    // Counters from the collection row next to what a scan can prove.
    public op stats(collection: string) -> Stats {
      route: "GET /v1/collections/:collection/stats"
      effects: store.find, store.fetch
      errors: NotFound
      post: result.vectors >= 0
      on error NotFound: collection != null
    }

    public op health() -> Health {
      route: "GET /v1/health"
      effects: store.find
      post: result.ok == true
    }
  }

  examples {
    example index_and_query {
      when {
        let c = createCollection("notes", 8, "cosine", 4, 2)
        let a = upsertVector("notes", "a", [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "{\"tag\":\"red\"}")
        let b = upsertVector("notes", "b", [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "{\"tag\":\"blue\"}")
        let q = query("notes", [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "", 1, "", 0, true, false)
      }
      then {
        c.dim == 8
        a.inserted == true
        q.hits != null
        q.exact == true
        q.k == 1
      }
    }

    example trained_search {
      when {
        let c = createCollection("colors", 8, "dot", 2, 1)
        let a = upsertVector("colors", "warm", [], "{\"tag\":\"warm\"}", "warm red sunset")
        let b = upsertVector("colors", "cold", [], "{\"tag\":\"cold\"}", "cold blue night")
        let r = rebuild("colors")
        let q = query("colors", [], "warm sunset", 2, "", 2, false, false)
        let s = stats("colors")
      }
      then {
        r.assigned == 2
        q.hits != null
        s.vectors == 2
        s.trained == true
      }
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  deploy docker
}