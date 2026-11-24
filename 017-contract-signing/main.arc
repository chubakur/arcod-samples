module contract_signing @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-24"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type EnvelopeId = uuid
type SignerId = uuid
type Stamp = datetime
type Document = bytes(min: 1, max: 512kb)

// The envelope is the control record: the document is sealed in the blob store
// under documentKey, and the row only carries the pointer and the counters.
type Envelope = {
  id: EnvelopeId,
  title: string,
  ownerEmail: email,
  documentKey: string,
  documentSize: int,
  status: string,
  signerCount: int,
  signedCount: int,
  createdAt: Stamp,
  sentAt: Stamp?,
  closedAt: Stamp?,
  lastNotifiedAt: Stamp?,
  reminders: int,
  manifestHash: string?
}

// One row per invited person. orderIndex is the turn in the signing route;
// code is the invitation secret the email carries. The signature is a sha256
// digest over the document text, the address and the signing instant.
type Signer = {
  id: SignerId,
  envelopeId: string,
  name: string,
  email: email,
  orderIndex: int,
  status: string,
  code: string,
  invitedAt: Stamp?,
  signedAt: Stamp?,
  declinedAt: Stamp?,
  signature: string?,
  reason: string?
}

type Audit = {
  id: uuid,
  envelopeId: string,
  kind: string,
  actor: string,
  detail: string,
  at: Stamp
}

type Notification = {
  id: uuid,
  envelopeId: string,
  signerId: string,
  kind: string,
  to: string,
  subject: string,
  at: Stamp
}

type EnvelopeView = { envelope: Envelope, signers: list<Signer>, audit: list<Audit> }

type ManifestSigner = {
  name: string,
  email: string,
  orderIndex: int,
  signedAt: Stamp?,
  signature: string?,
  verified: boolean
}

// The sealed artefact: it lives in S3, not in SQL, so the audit copy outlives
// any row. verified answers "does every signature still match the document".
type Manifest = {
  envelopeId: string,
  title: string,
  documentSize: int,
  sealedAt: Stamp,
  signers: list<ManifestSigner>,
  verified: boolean,
  intact: boolean
}

type Stats = {
  envelopes: int,
  completed: int,
  declined: int,
  pendingSigners: int,
  notifications: int
}

type Mail = {
  from: string,
  to: string,
  subject: string,
  text: string
}
type MailReply = { id: string }

external service Mailer : http {
  contract {
    op send(payload: Mail) -> MailReply {
      route: "POST /api/v1/send"
    }
  }
}

error Invalid
error Forbidden
error NotFound
error Conflict

service ContractSigning : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, uuid.new,
      files.put, files.get, events.publish, Mailer.send
  }

  contract {
    public op create(title: string, ownerEmail: email, document: Document) -> Envelope {
      route: "POST /v1/envelopes"
      effects: store.insert, files.put, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: title != null
    }

    public op addSigner(id: EnvelopeId, name: string, email: email) -> Signer {
      route: "POST /v1/envelopes/:id/signers"
      effects: store.fetch, store.count, store.insert, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op send(id: EnvelopeId) -> Envelope {
      route: "POST /v1/envelopes/:id/send"
      effects: store.fetch, store.count, store.update, events.publish
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op envelope(id: EnvelopeId) -> EnvelopeView {
      route: "GET /v1/envelopes/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.envelope != null
      on error NotFound: id != null
    }

    public op sign(id: EnvelopeId, email: email, code: string) -> EnvelopeView {
      route: "POST /v1/envelopes/:id/sign"
      effects: store.fetch, store.find, store.update, files.get, events.publish
      errors: Forbidden, NotFound, Conflict
      post: result.envelope != null
      on error Forbidden: email != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op decline(id: EnvelopeId, email: email, code: string, reason: string) -> EnvelopeView {
      route: "POST /v1/envelopes/:id/decline"
      effects: store.fetch, store.find, store.update, events.publish
      errors: Forbidden, Invalid, NotFound, Conflict
      post: result.envelope != null
      on error Forbidden: email != null
      on error Invalid: reason != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // The reminder tick. v0.1 has no scheduler for operations, so an operator
    // (or smoke) calls it; afterSec keeps it from mailing on every call.
    public op remind(id: EnvelopeId, afterSec: int = 3600) -> Envelope {
      route: "POST /v1/envelopes/:id/remind"
      effects: store.fetch, store.find, store.update, events.publish
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // The sealed manifest is read back from S3 and every signature is verified
    // against the document as it is stored today.
    public op manifest(id: EnvelopeId) -> Manifest {
      route: "GET /v1/envelopes/:id/manifest"
      effects: store.fetch, files.get
      errors: NotFound, Conflict
      post: result.envelopeId != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result.envelopes >= 0
    }

    // Test hook: overwrite the stored document so smoke can prove that the
    // manifest notices. Production has no route for this.
    public op tamper(id: EnvelopeId, document: Document) -> Envelope {
      route: "POST /v1/dev/envelopes/:id/tamper"
      effects: store.fetch, store.update, files.put
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    // Mail is delivered by a consumer, not by the request: the request only
    // says who to mail and why, so a slow gateway never fails the caller.
    job deliver(envelopeId: string, email: string, kind: string) {
      on: events.mail
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, uuid.new, Mailer.send
      errors: none
    }

    // Sealing is a separate consumer: it walks the signer rows, writes the
    // manifest to S3 and only then moves the envelope to completed.
    job seal(envelopeId: string) {
      on: events.seal
      retry: 2
      effects: store.fetch, store.find, store.update, store.insert, uuid.new, files.put
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Mailer -> endpoint(url: "http://mailer:9097")
  deploy docker
}
