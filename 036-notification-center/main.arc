module notification_center @0.1.0 {
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

type InputId = int
type TemplateId = uuid
type CampaignId = uuid
type DeliveryId = uuid

// A template is the copy the campaign renders. The body is a plain string with
// two placeholders; rendering is a body concern, not a language feature.
type Template = {
  id: TemplateId,
  code: string,
  name: string,
  subject: string,
  body: string,
  createdAt: int,
  active: boolean
}

type Recipient = {
  email: email,
  name: string
}

// The audience is stored as its own row set: the request may carry up to 200
// addresses, and the fan-out consumer must be able to re-read them after a
// restart without the original HTTP body.

type AudienceRow = {
  id: uuid,
  campaignId: string,
  email: email,
  name: string
}

// The campaign is the control record: the audience arrives in the request, the
// fan-out turns it into one delivery row per address.
type Campaign = {
  id: CampaignId,
  templateCode: string,
  name: string,
  audienceSize: int,
  status: string,
  createdAt: int,
  finishedAt: int?
}

// One delivery is one message: the row is the idempotency key, so a redelivered
// queue message cannot mail the same address twice.
type Delivery = {
  id: DeliveryId,
  campaignId: string,
  email: email,
  name: string,
  status: string,
  attempts: int,
  error: string?,
  sentAt: int?
}

// Four messages in one table, the rate per day and template is counted here
// rather than scanned from deliveries on every read.
type DayStat = {
  id: string,
  day: string,
  templateCode: string,
  sent: int,
  failed: int
}

type CampaignView = {
  campaign: Campaign,
  total: int,
  sent: int,
  failed: int,
  queued: int
}

type DeliveryPage = {
  items: list<Delivery>,
  total: int
}

type TemplatePage = {
  items: list<Template>,
  total: int
}

type DailyView = {
  items: list<DayStat>,
  sent: int,
  failed: int
}

type DeadView = {
  topic: string,
  total: int,
  ids: list<string>,
  errors: list<string>
}

type Report = {
  key: string,
  rows: int,
  sent: int,
  failed: int
}

type Ack = { ok: boolean, enqueued: int }

type Csv = bytes(min: 1, max: 512kb)

type Mail = {
  from: string,
  to: string,
  subject: string,
  text: string
}

type MailReply = { id: string }

// The vendor's send API. The provider is an endpoint, so the address lives in
// the environment, not in the model.
external service Mailer : http {
  contract {
    op send(payload: Mail) -> MailReply {
      route: "POST /api/v1/send"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Notifications : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, events.publish, events.dead, files.put, files.get, uuid.new, Mailer.send
  }

  contract {
    public op createTemplate(code: string, name: string, subject: string, body: string) -> Template {
      route: "POST /v1/templates"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: code != null
      on error Conflict: code != null
    }

    public op templates() -> TemplatePage {
      route: "GET /v1/templates"
      effects: store.find, store.count
      errors: none
      post: result.total >= 0
    }

    // The audience is part of the request; only its size and the campaign row
    // reach the database until the fan-out consumer splits it.
    public op createCampaign(templateCode: string, name: string, audience: list<Recipient>) -> Campaign {
      route: "POST /v1/campaigns"
      effects: store.find, store.insert, events.publish, uuid.new
      errors: Invalid, NotFound
      post: result.id != null
      on error Invalid: name != null
      on error NotFound: templateCode != null
    }

    public op campaign(id: CampaignId) -> CampaignView {
      route: "GET /v1/campaigns/:id"
      effects: store.fetch, store.count
      errors: NotFound
      post: result.campaign != null
      on error NotFound: id != null
    }

    public op deliveries(id: CampaignId) -> DeliveryPage {
      route: "GET /v1/campaigns/:id/deliveries"
      effects: store.find, store.count
      errors: none
      post: result.total >= 0
    }

    // The analytics export: deliveries become a CSV row set in object storage,
    // the report answer carries the key and the totals.
    public op report(id: CampaignId) -> Report {
      route: "GET /v1/campaigns/:id/report"
      effects: store.fetch, store.find, store.count, files.put
      errors: NotFound
      post: result.rows >= 0
      on error NotFound: id != null
    }

    public op reportFile(id: CampaignId) -> { name: string, type: string, body: Csv } {
      route: "GET /v1/campaigns/:id/report.csv"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.body != null
      on error NotFound: id != null
    }

    public op daily() -> DailyView {
      route: "GET /v1/daily"
      effects: store.find
      errors: none
      post: result.sent >= 0
    }

    // The operations view of the queue: what exhausted its retry budget.
    public op dead() -> DeadView {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result.total >= 0
    }

    // Test helper: re-publish the fan-out. The consumer must notice the done
    // campaign and not enqueue a second round.
    public op fanoutAgain(id: CampaignId) -> Ack {
      route: "POST /v1/admin/fanout/:id"
      effects: store.fetch, events.publish
      errors: NotFound
      post: result.ok == true
      on error NotFound: id != null
    }

    // Split one campaign into per-recipient deliveries, then hand each one to
    // the deliver topic. Re-entry is safe: existing rows are skipped.
    job fanout(campaignId: string) {
      on: events.fanout
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, events.publish, uuid.new
      errors: none
    }

    // One message per delivery: render, send, record. A failed send stays on
    // the queue until the retry budget runs out, then lands in the dead letter.
    job deliver(deliveryId: string) {
      on: events.deliver
      retry: 2
      effects: store.fetch, store.find, store.update, store.count, Mailer.send
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Mailer -> endpoint(url: "http://mailer:9096")
  deploy docker
}
