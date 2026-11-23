module video_platform @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-23"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type VideoId = uuid
type RenditionId = uuid
type Stamp = string

// A video row is the control record: where the source lives, how far the
// pipeline got and what the owner sees. The bytes never enter the database.
type Video = {
  id: VideoId,
  title: string,
  owner: string,
  checksum: string,
  contentType: string,
  status: string,
  sourceKey: string,
  sourceBytes: int,
  durationSec: int,
  previewKey: string?,
  attempts: int,
  error: string?,
  createdAt: Stamp,
  updatedAt: Stamp
}

// One row per preset per video: the consumer writes it after S3 accepted the
// object, so a rendition row always points at bytes that exist.
type Rendition = {
  id: RenditionId,
  videoId: VideoId,
  preset: string,
  key: string,
  sizeBytes: int,
  bitrateKbps: int,
  createdAt: Stamp
}

type Delivery = { id: string, videoId: VideoId, status: string, at: Stamp }

type Stats = { total: int, ready: int, failed: int, transcoding: int, sourceBytes: int }
type Progress = { video: Video, renditions: list<Rendition>, ready: int, total: int }
type Ack = { ok: boolean, queued: int }
type Source = bytes(min: 1, max: 64kb)

type ReadyEvent = { videoId: string, title: string, previewKey: string, renditions: int }
type HookAck = { received: boolean }

external service Hook : http {
  contract {
    op ready(payload: ReadyEvent) -> HookAck {
      route: "POST /v1/ready"
    }
  }
}

error Invalid
error NotFound
error Conflict

service VideoPlatform : http {
  uses store: sql(ttl: 2592000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, uuid.new, events.publish, files.put, files.get, Hook.ready
    deny net, fs, exec
  }

  rules {
    // The client sends a checksum of the source: the second upload of the same
    // bytes is the same video, and the database enforces it, not the handler.
    unique Video.checksum
  }

  contract {
    // Upload is synchronous for the bytes and asynchronous for the work:
    // S3 gets the object before the answer, the consumer does the rest.
    public op upload(title: string, owner: string, checksum: string, contentType: string, durationSec: int, body: Source) -> Video {
      route: "POST /v1/videos"
      effects: store.find, store.insert, files.put, events.publish, uuid.new
      errors: Invalid, Conflict
      post: result.status != null
      on error Invalid: title != null
      on error Conflict: checksum != null
    }

    public op video(id: VideoId) -> Progress {
      route: "GET /v1/videos/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.total >= 0
      on error NotFound: id != null
    }

    public op videos(limit: int) -> list<Video> {
      route: "GET /v1/videos"
      effects: store.find
      errors: none
      post: result != null
    }

    // The source is readable through the service, not through a public bucket:
    // the key is a server-side detail.
    public op source(id: VideoId) -> { name: string, type: string, body: Source } {
      route: "GET /v1/videos/:id/source"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.body != null
      on error NotFound: id != null
    }

    public op renditionFile(id: RenditionId) -> { name: string, type: string, body: Source } {
      route: "GET /v1/renditions/:id/file"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.body != null
      on error NotFound: id != null
    }

    // Retry is allowed only for a failed video, and it resets the counter so
    // the consumer gets the full budget again.
    public op retry(id: VideoId) -> Ack {
      route: "POST /v1/videos/:id/retry"
      effects: store.fetch, store.update, events.publish
      errors: NotFound, Conflict
      post: result.ok == true
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // Stuck work is a fact of life: a consumer that died mid-flight leaves a
    // row in transcoding. The sweep republishes it with the same idempotent body.
    public op sweep() -> Ack {
      route: "POST /v1/admin/sweep"
      effects: store.find, store.update, events.publish
      errors: none
      post: result.ok == true
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result.total >= 0
    }

    // Consumer one: one message per preset. At-least-once, so it checks the
    // rendition row before touching S3.
    job transcode(videoId: VideoId) {
      on: events.transcode
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, store.count, files.get, files.put, events.publish, uuid.new
      errors: none
    }

    // Consumer two: the only place that talks to the outside world about a
    // finished video. Failure here does not make the video unready.
    job notify(videoId: VideoId, renditions: int) {
      on: events.ready
      retry: 1
      effects: store.fetch, store.find, store.insert, uuid.new, Hook.ready
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Hook -> endpoint(url: "http://localhost:9098")
  deploy docker
}

environment test {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Hook -> endpoint(url: "http://localhost:9098")
  deploy docker
}
