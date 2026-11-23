module gdpr_erasure @0.1.0 {
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

type RequestId = uuid
type Stamp = string

// An erasure request is the control record of one data-subject ask. It keeps
// a hash, never the address: the service has to find PII, not store more of it.
type ErasureRequest = {
  id: RequestId,
  subjectHash: string,
  subjectLabel: string,
  reason: string,
  state: string,
  datasets: int,
  rowsDeleted: int,
  attempts: int,
  reportKey: string,
  certificate: string,
  createdAt: Stamp,
  updatedAt: Stamp
}

// Three CRM tables that hold personal data. Every row carries subjectHash, so
// the cascade is one indexed lookup per table, not a full scan per dataset.
type Customer = {
  id: uuid,
  subjectHash: string,
  email: string,
  name: string,
  plan: string,
  createdAt: Stamp
}

type OrderNote = {
  id: uuid,
  customerId: uuid,
  subjectHash: string,
  body: string,
  createdAt: Stamp
}

type SupportTicket = {
  id: uuid,
  subjectHash: string,
  subject: string,
  body: string,
  status: string,
  createdAt: Stamp
}

// The audit log is what survives the deletion: it names datasets and counts,
// never values. It is also the resume marker of the consumer.
type AuditEntry = {
  id: uuid,
  requestId: string,
  subjectHash: string,
  dataset: string,
  action: string,
  rows: int,
  at: Stamp
}

type DatasetCount = { dataset: string, rows: int }
type Status = { request: ErasureRequest, manifest: list<AuditEntry>, remaining: list<DatasetCount> }
type SubjectView = { subjectHash: string, remaining: list<DatasetCount>, requests: int, active: int }
type Stats = { total: int, pending: int, erasing: int, erased: int, certified: int, failed: int, rowsErased: int }
type Ack = { ok: boolean, queued: int }
type Source = bytes(min: 1, max: 128kb)

type Certificate = { requestId: string, subjectHash: string, rowsDeleted: int, reportKey: string }
type CertAck = { accepted: boolean, certificate: string }

// The compliance gateway is another company's service: it issues the legal
// certificate and keeps its own copy. We only know its contract and address.
external service Compliance : http {
  contract {
    op certify(payload: Certificate) -> CertAck {
      route: "POST /v1/certificates"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Erasure : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, store.remove, uuid.new, events.publish, files.put, files.get, Compliance.certify
    deny net, fs, exec
  }

  contract {
    // A request is accepted in one write and then handed to the queue: the
    // cascade is minutes of work, not a request timeout.
    public op create(subjectEmail: string, reason: string) -> ErasureRequest {
      route: "POST /v1/requests"
      effects: store.find, store.insert, events.publish, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: subjectEmail != null
      on error Conflict: subjectEmail != null
    }

    public op requests(limit: int) -> list<ErasureRequest> {
      route: "GET /v1/requests"
      effects: store.find
      errors: none
      post: result != null
    }

    public op show(id: RequestId) -> Status {
      route: "GET /v1/requests/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.request != null
      on error NotFound: id != null
    }

    // The certificate is bytes in S3: the API serves them through the service
    // so the bucket never needs a public policy.
    public op certificate(id: RequestId) -> { name: string, type: string, body: Source } {
      route: "GET /v1/requests/:id/certificate"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.body != null
      on error NotFound: id != null
    }

    // Residue check: proves that nothing is left for the subject and that the
    // other subjects were not touched.
    public op subject(subjectEmail: string) -> SubjectView {
      route: "GET /v1/subjects/:subjectEmail"
      effects: store.find, store.count
      errors: Invalid
      post: result.remaining != null
      on error Invalid: subjectEmail != null
    }

    // Retry is for the operator, after the compliance gateway came back.
    public op retry(id: RequestId) -> Ack {
      route: "POST /v1/requests/:id/retry"
      effects: store.fetch, store.update, events.publish
      errors: NotFound, Conflict
      post: result.ok == true
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // A consumer that died mid-cascade leaves a request in erasing forever.
    // The sweep republishes it; the consumer resumes from the audit log.
    public op sweep() -> Ack {
      route: "POST /v1/sweep"
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

    // Demo data only: three tables of PII for two subjects.
    public op seed() -> Ack {
      route: "POST /v1/dev/seed"
      effects: store.find, store.insert, uuid.new
      errors: none
      post: result.ok == true
    }

    // Consumer one: delete the rows table by table, then write the manifest.
    job erase(requestId: RequestId) {
      on: events.erase
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, store.remove, files.put, events.publish, uuid.new
      errors: none
    }

    // Consumer two: only this job talks to the compliance gateway. A failed
    // certificate does not make the deletion a lie; it stays erased and waits.
    job certify(requestId: RequestId) {
      on: events.erased
      retry: 3
      effects: store.fetch, store.find, store.insert, store.update, Compliance.certify, uuid.new
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Compliance -> endpoint(url: "http://localhost:9097")
}

environment test {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Compliance -> endpoint(url: "http://localhost:9097")
}
