module collab_editor @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.stream @1
use capability arcod.std.ids @1

type DocId = uuid
type OpId = uuid
type CommentId = uuid
type RevisionId = uuid

// The document row holds metadata; text and version are replayed from the
// operation log on read, so two parallel writers never lose each other's edit.
type Doc = {
  id: DocId,
  title: string,
  owner: string,
  content: string,
  version: int,
  snapshotKey: string?,
  snapshotVersion: int,
  createdAt: datetime,
  updatedAt: datetime
}

// One edit. kind is "insert" or "delete"; for delete, text is the removed
// fragment (its length is the number of characters removed, empty means one).
// version is the ordinal of the row in the log, not a stored field.
type OpInput = {
  clientId: string,
  seq: int,
  kind: string,
  pos: int,
  text: string = ""
}

type Op = {
  id: OpId,
  docId: string,
  clientId: string,
  seq: int,
  kind: string,
  pos: int,
  text: string,
  version: int,
  at: datetime
}

type OpResult = {
  docId: string,
  version: int,
  duplicate: boolean,
  content: string
}

type Revision = {
  id: RevisionId,
  docId: string,
  version: int,
  key: string,
  ops: int,
  createdAt: datetime
}

type CursorInput = {
  clientId: string,
  pos: int,
  name: string = ""
}

type CursorResult = {
  delivered: int,
  version: int
}

type CommentInput = {
  author: string,
  body: string
}

type Comment = {
  id: CommentId,
  docId: string,
  author: string,
  body: string,
  status: string,
  createdAt: datetime
}

type CommentResult = {
  comment: Comment,
  notified: boolean
}

type Snapshot = {
  docId: string,
  version: int,
  key: string,
  content: string
}

type Stats = {
  docs: int,
  ops: int,
  comments: int,
  revisions: int
}

error Invalid
error NotFound
error Conflict

service Docs : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses live: stream
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, store.remove, events.publish, events.dead, files.put, files.get, live.publish, uuid.new
  }

  // Two retries of the same edit cannot both land: the pair (clientId, seq)
  // is unique per document, so the database, not the handler, wins the race.
  rules {
    unique Op.(docId, clientId, seq)
  }

  contract {
    public op create(title: string, owner: string) -> Doc {
      route: "POST /v1/docs"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: title != null
    }

    public op list(limit: int = 20) -> list<Doc> {
      route: "GET /v1/docs"
      effects: store.find
      errors: none
      post: result != null
    }

    public op get(id: DocId) -> Doc {
      route: "GET /v1/docs/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    // Idempotent by (clientId, seq): a retried edit returns the stored version
    // instead of appending a second one.
    public op applyOp(id: DocId, clientId: string, seq: int, kind: string, pos: int, text: string = "") -> OpResult {
      route: "POST /v1/docs/:id/ops"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, live.publish, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.version >= 1
      on error Invalid: clientId != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op ops(id: DocId, since: int = 0) -> list<Op> {
      route: "GET /v1/docs/:id/ops"
      effects: store.find, store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    // Presence is not stored: the cursor goes straight to the live topic and
    // the reply says how many sockets received it.
    public op cursor(id: DocId, clientId: string, pos: int, name: string = "") -> CursorResult {
      route: "POST /v1/docs/:id/cursor"
      effects: store.fetch, live.publish
      errors: Invalid, NotFound
      post: result.delivered >= 0
      on error Invalid: clientId != null
      on error NotFound: id != null
    }

    public op comment(id: DocId, author: string, body: string) -> CommentResult {
      route: "POST /v1/docs/:id/comments"
      effects: store.fetch, store.insert, events.publish, live.publish, uuid.new
      errors: Invalid, NotFound
      post: result.comment.id != null
      on error Invalid: body != null
      on error NotFound: id != null
    }

    public op comments(id: DocId) -> list<Comment> {
      route: "GET /v1/docs/:id/comments"
      effects: store.find, store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    // Compaction is explicit here: the caller pays for the write and gets the
    // snapshot back. The background job does the same thing when the log grows.
    public op snapshot(id: DocId) -> Snapshot {
      route: "POST /v1/docs/:id/snapshot"
      effects: store.fetch, store.find, store.insert, store.update, files.put, live.publish, uuid.new
      errors: NotFound
      post: result.version >= 0
      on error NotFound: id != null
    }

    public op latest(id: DocId) -> Snapshot {
      route: "GET /v1/docs/:id/snapshot"
      effects: store.fetch, store.find, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op revisions(id: DocId) -> list<Revision> {
      route: "GET /v1/docs/:id/revisions"
      effects: store.find, store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result.docs >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // Folding the log happens off the request path. A redelivered job finds the
    // revision row and returns without writing a second snapshot.
    job compact(docId: string) {
      on: events.compact
      retry: 1
      effects: store.fetch, store.find, store.insert, store.update, files.put, live.publish, uuid.new
      errors: none
    }

    // A comment is durable first; the notification is a separate step.
    job notify(commentId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.update, live.publish
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind live -> websocket()
  bind uuid -> local
  deploy docker
}
