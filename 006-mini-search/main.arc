module mini_search @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1

// A document and its postings are separate records. The document is the
// commit point: postings from version N are invisible until Doc.version is N.
// That turns a replace into "write the new generation, then flip the version"
// and keeps a half-finished reindex out of the answer set.

type DocId = uuid

type Doc = {
  id: DocId,
  title: string,
  body: string,
  tags: string,
  length: int,
  version: int,
  createdAt: datetime,
  updatedAt: datetime
}

// One term in one document at one generation. The composite claim is what
// makes indexing a write-once operation: a retry or a racing writer either
// lands the same posting or loses the whole generation with Conflict.
type Posting = {
  id: string,
  term: string,
  docId: DocId,
  version: int,
  tf: int,
  titleTf: int
}

// Terms exist independently of documents so prefix suggestions do not need a
// scan of every posting. A term is never deleted: stale vocabulary is cheaper
// than a tombstone protocol over a store without compare-and-swap.
type Term = {
  id: string,
  term: string,
  at: datetime
}

// Denormalised corpus counters for BM25. Updated on every write; a concurrent
// writer can make it drift (there is no CAS, arcod#10), so /v1/stats also
// reports the values a scan can prove.
type Corpus = {
  id: string,
  documents: int,
  totalLength: int,
  updatedAt: datetime
}

type IndexResult = {
  doc: Doc,
  postings: int,
  terms: int
}

type DeleteResult = {
  deleted: bool,
  postings: int
}

type SearchHit = {
  docId: DocId,
  title: string,
  tags: string,
  score: float,
  snippet: string,
  matched: list<string>
}

type SearchPage = {
  query: string,
  total: int,
  offset: int,
  limit: int,
  tookMs: int,
  hits: list<SearchHit>
}

type IndexStats = {
  documents: int,
  scannedDocs: int,
  postings: int,
  terms: int,
  avgLength: float
}

type Health = {
  ok: bool,
  documents: int
}

error Invalid
error NotFound
error Conflict

service MiniSearch : http {
  uses store: kv(ttl: 604800s)
  uses uuid: ids

  effects {
    allow store.find, store.insert, store.update, store.remove, store.fetch, store.get, store.set, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Posting.(term, docId, version)
    unique Term.term
  }

  contract {
    // Index a new document. The body is tokenised, stopwords are dropped and
    // every surviving term gets a posting with its frequency.
    public op indexDoc(title: string, body: string, tags: string = "") -> IndexResult {
      route: "POST /v1/docs"
      effects: store.find, store.insert, store.update, store.fetch, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: title != null
      on error Conflict: title != null
    }

    // Replace a document. New postings are written at version + 1; the update
    // of Doc.version is the moment the new generation becomes visible.
    public op updateDoc(id: DocId, title: string, body: string, tags: string = "") -> IndexResult {
      route: "PUT /v1/docs/:id"
      effects: store.find, store.insert, store.update, store.remove, store.fetch, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result != null
      on error Invalid: title != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // Delete the document first: search ignores postings whose document is
    // gone, so cleanup can be best-effort.
    public op deleteDoc(id: DocId) -> DeleteResult {
      route: "DELETE /v1/docs/:id"
      effects: store.find, store.remove, store.fetch
      errors: NotFound
      post: result.deleted == true
      on error NotFound: id != null
    }

    public op getDoc(id: DocId) -> Doc {
      route: "GET /v1/docs/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    // q supports +term (required), -term (excluded), a quoted phrase and
    // tag:name. Plain terms are optional but scored; all supplied filters
    // must hold.
    public op search(q: string, limit: int = 10, offset: int = 0) -> SearchPage {
      route: "GET /v1/search"
      effects: store.find, store.fetch
      errors: Invalid
      post: result.hits != null
      on error Invalid: q != null
    }

    public op suggest(prefix: string, limit: int = 8) -> list<string> {
      route: "GET /v1/suggest"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: prefix != null
    }

    public op stats() -> IndexStats {
      route: "GET /v1/stats"
      effects: store.find, store.fetch
      post: result.documents >= 0
    }

    public op health() -> Health {
      route: "GET /v1/health"
      effects: store.find, store.fetch
      post: result.ok == true
    }
  }

  examples {
    example index_and_rank {
      when {
        let a = indexDoc("Zorblat notes", "A zorblat token only grows with every lease.", "locks")
        let b = indexDoc("Quuxly index", "A quuxly index maps zorblat terms to documents.", "search")
        let page = search("+quuxly +zorblat", 10, 0)
        let one = getDoc(b.doc.id)
      }
      then {
        page.total == 1
        page.hits != null
        one.title == "Quuxly index"
      }
    }

    example reindex_hides_old_terms {
      when {
        let a = indexDoc("Zephyrix notes", "A lease carries a zephyrix token.", "locks")
        let b = updateDoc(a.doc.id, "Zephyrium notes", "A lease carries a zephyrium number.", "locks")
      }
      then {
        b.doc.version == 2
        search("zephyrix", 10, 0).total == 0
        search("zephyrium", 10, 0).total == 1
      }
    }

    example delete_and_suggest {
      when {
        let a = indexDoc("Kryofax notes", "A kryofax index supports kryorecall.", "search")
        let words = suggest("kryo", 5)
        let gone = deleteDoc(a.doc.id)
      }
      then {
        words != null
        gone.deleted == true
        search("kryorecall", 10, 0).total == 0
      }
    }

    example counters {
      when {
        let h = health()
        let t = stats()
      }
      then {
        h.ok == true
        t.documents >= 0
        t.scannedDocs >= 0
      }
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  deploy docker
}
