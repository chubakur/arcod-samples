module field_dispatch @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-20"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type TicketId = uuid
type TechId = uuid
type Stamp = string

type Ticket = {
  id: TicketId,
  code: string,
  customer: string,
  email: email,
  city: string,
  address: string,
  category: string,
  priority: int,
  status: string,
  createdAt: Stamp,
  dueAt: Stamp,
  technicianId: TechId?,
  technician: string?,
  etaMinutes: int?,
  note: string?,
  photoKeys: string,
  closedAt: Stamp?
}

type Tech = {
  id: TechId,
  name: string,
  city: string,
  skills: string,
  active: boolean,
  load: int
}

type Photo = { key: string, body: string, type: string }

type Stats = { city: string, open: int, assigned: int, done: int }

type Offer = { ticketId: TicketId, city: string, category: string, priority: int }
type OfferAck = { accepted: boolean, technician: string?, eta: int? }

type Notice = { ticketId: TicketId, code: string, message: string }
type Ack = { ok: boolean, ref: string }

external service Router : http {
  contract {
    op offer(ticket: Offer) -> OfferAck {
      route: "POST /v1/offers"
    }
    op notify(notice: Notice) -> Ack {
      route: "POST /v1/notify"
    }
  }
}

error Invalid
error NotFound
error Conflict

service FieldDispatch : http {
  uses store: sql(ttl: 2592000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, uuid.new, events.publish, files.put, files.get, Router.offer, Router.notify
    deny net, fs, exec
  }

  rules {
    unique Ticket.code
  }

  contract {
    public op open(customer: string, email: email, city: string, address: string, category: string, priority: int) -> Ticket {
      route: "POST /v1/tickets"
      effects: store.insert, uuid.new, events.publish
      errors: Invalid
      post: result != null
      on error Invalid: city != null
    }

    public op registerTech(name: string, city: string, skills: list<string>) -> Tech {
      route: "POST /v1/technicians"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    public op get(id: TicketId) -> Ticket {
      route: "GET /v1/tickets/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op board(city: string, status: string) -> list<Ticket> {
      route: "GET /v1/tickets"
      effects: store.find
      errors: none
      post: result != null
    }

    public op stats(city: string) -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result != null
    }

    public op complete(id: TicketId, note: string, photos: list<Photo>) -> Ticket {
      route: "POST /v1/tickets/:id/complete"
      effects: store.fetch, store.update, files.put, events.publish
      errors: NotFound, Conflict
      post: result != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op report(id: TicketId) -> list<string> {
      route: "GET /v1/tickets/:id/report"
      effects: store.fetch, files.get
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    job dispatch(ticketId: TicketId) {
      on: events.dispatch
      retry: 3
      effects: store.fetch, store.update, store.find, Router.offer
      errors: none
    }

    job notify(ticketId: TicketId) {
      on: events.notify
      retry: 2
      effects: store.fetch, Router.notify
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Router -> endpoint(url: "http://localhost:9098")
  deploy docker
}
