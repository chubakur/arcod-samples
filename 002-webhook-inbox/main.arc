module webhook_inbox @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-18"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1
use capability arcod.std.queue @1

type EventId = uuid
type Event = {
  id: EventId,
  source: string,
  key: string,
  eventType: string,
  payload: string,
  status: string,
  attempts: int,
  failFirst: int,
  receivedAt: datetime,
  deliveredAt: datetime?
}
type Receipt = { event: Event, duplicate: bool }
type EventPage = { items: list<Event>, next: string? }
type Stats = { received: int, pending: int, retrying: int, delivered: int, dead: int }

error Invalid
error NotFound

service WebhookInbox : http {
  uses store: kv(ttl: 2592000s, consistency: strong)
  uses uuid: ids
  uses events: queue

  effects {
    allow store.get, store.set, store.insert, store.find, store.update, uuid.new, events.publish
  }

  contract {
    public op ingest(source: string, key: string, eventType: string, payload: string, failFirst: int?) -> Receipt {
      route: "POST /v1/hooks/:source"
      effects: store.get, store.set, store.insert, store.find, uuid.new, events.publish
      errors: Invalid
      post: result != null
      on error Invalid: source != null
    }

    public op getEvent(id: EventId) -> Event {
      route: "GET /v1/events/:id"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op listEvents(source: string?, status: string?, limit: int?) -> EventPage {
      route: "GET /v1/events"
      effects: store.find
      post: result.items != null
    }

    public op redeliver(id: EventId) -> Event {
      route: "POST /v1/events/:id/redeliver"
      effects: store.find, store.update, events.publish
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.find
      post: result != null
    }

    job deliver(eventId: string) {
      on: events.deliveries
      retry: 3
      effects: store.find, store.update
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  bind events -> redis(host: "queue", port: 6379)
  deploy docker
}
