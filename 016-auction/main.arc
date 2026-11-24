module auction @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-24"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.ids @1

type LotId = uuid
type Stamp = int

// A lot is the control record: money lives in cents, time in epoch seconds,
// so the anti-sniping rule is plain integer arithmetic in the body.
type Lot = {
  id: LotId,
  title: string,
  seller: string,
  sellerEmail: email,
  startCents: int,
  reserveCents: int,
  endsAt: Stamp,
  state: string,
  highBidCents: int,
  highBidder: string,
  extensions: int,
  closedAt: Stamp?
}

type Bid = {
  id: uuid,
  lotId: string,
  bidder: string,
  amountCents: int,
  at: Stamp,
  state: string
}

// Every message the gateway accepted. The row is the receipt the operator can
// replay; the mail itself lives at the vendor.
type Notification = {
  id: uuid,
  lotId: string,
  kind: string,
  to: string,
  subject: string,
  at: Stamp
}

type LotView = { lot: Lot, bids: list<Bid> }
type Stats = { closedLots: int, bidVolume: int, notifications: int }
type Ack = { ok: boolean, closed: int }

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
error NotFound
error Conflict

service Auction : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses uuid: ids

  contract {
    public op createLot(title: string, seller: string, sellerEmail: email, startCents: int, reserveCents: int, durationSec: int) -> Lot {
      route: "POST /v1/lots"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: title != null
    }

    // A bid is accepted, outbids and possibly extends the lot. The body owns
    // the three rules; the route only says who is bidding.
    public op placeBid(lotId: string, bidder: string, amountCents: int) -> LotView {
      route: "POST /v1/lots/:lotId/bids"
      effects: store.fetch, store.insert, store.update, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.lot != null
      on error Invalid: amountCents != null
      on error NotFound: lotId != null
      on error Conflict: lotId != null
    }

    public op lot(lotId: string) -> LotView {
      route: "GET /v1/lots/:lotId"
      effects: store.fetch, store.find
      errors: NotFound
      post: result != null
      on error NotFound: lotId != null
    }

    // The closing tick. In production a workflow with a cron trigger calls it;
    // v0.1 has no scheduler for operations, so the operator (or smoke) drives it.
    public op closeDue() -> Ack {
      route: "POST /v1/admin/close"
      effects: store.find, store.update, events.publish
      errors: none
      post: result.closed >= 0
    }

    // Test helper: a lot never waits for the wall clock in CI. Production uses
    // the closing tick; smoke uses this to make a lot due immediately.
    public op expire(lotId: string) -> Lot {
      route: "POST /v1/dev/lots/:lotId/expire"
      effects: store.fetch, store.update
      errors: NotFound
      post: result != null
      on error NotFound: lotId != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.aggregate
      errors: none
      post: result != null
    }

    // Demo data: two live lots with different reserves.
    public op seed() -> Ack {
      route: "POST /v1/dev/seed"
      effects: store.insert, uuid.new
      errors: none
      post: result.ok == true
    }

    // One consumer, one message per closed lot: mail the seller, mail the
    // winner when the reserve was met. At-least-once, so the notification rows
    // are the idempotency key.
    job notify(lotId: string) {
      on: events.notify
      retry: 2
      effects: store.fetch, store.find, store.insert, Mailer.send, uuid.new
      errors: none
    }
  }

  effects {
    allow store.insert, store.fetch, store.find, store.update, store.count, store.aggregate, events.publish, uuid.new, Mailer.send
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind uuid -> local
  bind Mailer -> endpoint(url: "http://mailer:9096")
  deploy docker
}
