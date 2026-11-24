module email_bridge @0.1.0 {
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

type MailboxId = uuid
type RouteId = uuid
type MessageId = uuid
type DeliveryId = uuid
type AttachmentId = uuid

// A mailbox is an address plus the cursor into the provider's inbox. The
// secret never leaves the API: it signs the payload the sink receives.
type Mailbox = {
  id: MailboxId,
  address: string,
  secret: string,
  cursor: string,
  active: boolean,
  createdAt: int
}

// The creation answer carries the secret once; the read answer does not.
type MailboxSecret = {
  id: MailboxId,
  address: string,
  secret: string,
  cursor: string,
  createdAt: int
}

type MailboxView = {
  id: MailboxId,
  address: string,
  cursor: string,
  createdAt: int,
  routes: int,
  messages: int
}

// A route is a string match on the envelope. The first matching route wins,
// and its topic is what the subscriber sees.
type Route = {
  id: RouteId,
  mailboxId: string,
  topic: string,
  fromContains: string,
  subjectContains: string,
  active: boolean,
  createdAt: int
}

type Attachment = {
  id: AttachmentId,
  messageId: string,
  name: string,
  contentType: string,
  key: string,
  bytes: int,
  sha256: string
}

type Message = {
  id: MessageId,
  mailboxId: string,
  externalId: string,
  fromAddress: string,
  toAddress: string,
  subject: string,
  receivedAt: int,
  bodyKey: string,
  bodyBytes: int,
  digest: string,
  attachmentCount: int,
  topic: string,
  status: string,
  createdAt: int
}

type Delivery = {
  id: DeliveryId,
  messageId: string,
  mailboxId: string,
  topic: string,
  status: string,
  attempts: int,
  lastError: string,
  createdAt: int,
  deliveredAt: int
}

type MessageView = {
  message: Message,
  body: string,
  attachments: list<Attachment>
}

type MessagePage = { items: list<Message>, total: int }
type PollResult = { queued: int, mailboxes: int }
type Stats = {
  messages: int,
  delivered: int,
  failed: int,
  retrying: int,
  ignored: int,
  attachments: int,
  dead: int
}

// The inbound provider answers a pull with the messages after the cursor.
type InboundAttachment = {
  name: string,
  contentType: string,
  contentBase64: string
}

type InboundMessage = {
  id: string,
  from: string,
  to: string,
  subject: string,
  receivedAt: int,
  text: string,
  attachments: list<InboundAttachment>
}

type InboxBatch = { messages: list<InboundMessage>, cursor: string }
type InboxQuery = { mailbox: string, after: string }

type WebhookAttachment = {
  name: string,
  contentType: string,
  key: string,
  bytes: int,
  sha256: string
}

type WebhookPayload = {
  deliveryId: string,
  messageId: string,
  mailbox: string,
  topic: string,
  from: string,
  subject: string,
  receivedAt: int,
  bodyKey: string,
  bodyBytes: int,
  attachments: list<WebhookAttachment>,
  signature: string
}

type SinkAck = { received: boolean, id: string }

external service Inbox : http {
  contract {
    op pull(query: InboxQuery) -> InboxBatch {
      route: "POST /pull"
    }
  }
}

external service Sink : http {
  contract {
    op deliver(payload: WebhookPayload) -> SinkAck {
      route: "POST /hooks/email"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Bridge : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, events.publish, events.dead, files.put, files.get, uuid.new, Inbox.pull, Sink.deliver
  }

  contract {
    // The secret is generated here, not accepted from the client.
    public op createMailbox(address: string) -> MailboxSecret {
      route: "POST /v1/mailboxes"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.secret != null
      on error Invalid: address != null
      on error Conflict: address != null
    }

    public op mailbox(id: MailboxId) -> MailboxView {
      route: "GET /v1/mailboxes/:id"
      effects: store.fetch, store.count
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    public op createRoute(mailboxId: MailboxId, topic: string, fromContains: string, subjectContains: string) -> Route {
      route: "POST /v1/routes"
      effects: store.fetch, store.find, store.insert, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: topic != null
      on error NotFound: mailboxId != null
      on error Conflict: topic != null
    }

    // Poll is the cron hook: it does not touch the inbox, it only queues one
    // ingest job per active mailbox.
    public op poll(id: MailboxId) -> PollResult {
      route: "POST /v1/mailboxes/:id/poll"
      effects: store.fetch, events.publish
      errors: NotFound, Conflict
      post: result.queued >= 0
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op messages() -> MessagePage {
      route: "GET /v1/messages"
      effects: store.find, store.count
      errors: none
      post: result.total >= 0
    }

    public op message(id: MessageId) -> MessageView {
      route: "GET /v1/messages/:id"
      effects: store.fetch, store.find, files.get
      errors: NotFound
      post: result.message.id != null
      on error NotFound: id != null
    }

    // Replay only exists for a delivery that failed for good.
    public op replay(id: MessageId) -> Delivery {
      route: "POST /v1/messages/:id/replay"
      effects: store.fetch, store.find, store.update, store.insert, events.publish, uuid.new
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, events.dead
      errors: none
      post: result.messages >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
    }

    // The consumer: pulls new mail, writes body and attachments to object
    // storage, inserts the durable rows, then queues one delivery per message.
    job ingest(mailboxId: string) {
      on: events.ingest
      retry: 3
      effects: store.fetch, store.find, store.insert, store.update, files.put, uuid.new, Inbox.pull, events.publish
      errors: none
    }

    // The second consumer: signs the payload and hands it to the subscriber.
    // A non-2xx answer is a failure, so the queue retries and then dead-letters.
    job deliver(deliveryId: string) {
      on: events.deliver
      retry: 2
      effects: store.fetch, store.find, store.update, Sink.deliver
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Inbox -> endpoint(url: "http://inbox:9097")
  bind Sink -> endpoint(url: "http://sink:9098")
  deploy docker
}
