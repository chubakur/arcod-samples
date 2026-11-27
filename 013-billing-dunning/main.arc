module billing_dunning @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-20"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.kv @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type PlanId = uuid
type SubId = uuid
type InvoiceId = uuid
type Stamp = string

type Plan = {
  id: PlanId,
  code: string,
  name: string,
  priceCents: int,
  intervalDays: int,
  active: boolean
}

type Subscription = {
  id: SubId,
  planCode: string,
  customer: string,
  email: email,
  cardToken: string,
  status: string,
  periodStart: Stamp,
  periodEnd: Stamp,
  intervalDays: int,
  attempts: int,
  createdAt: Stamp
}

type Invoice = {
  id: InvoiceId,
  subscriptionId: SubId,
  customer: string,
  amountCents: int,
  status: string,
  attempts: int,
  lastError: string?,
  gatewayRef: string?,
  receiptKey: string?,
  issuedAt: Stamp,
  paidAt: Stamp?
}

type Stats = { active: int, pastDue: int, collectedCents: int, failedCents: int }
type ChargeRequest = { invoiceId: string, amountCents: int, cardToken: string, idempotencyKey: string }
type ChargeReply = { status: string, ref: string?, code: string? }
type Ack = { ok: boolean, count: int }

external service Gateway : http {
  contract {
    op charge(payload: ChargeRequest) -> ChargeReply {
      route: "POST /v1/charge"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Billing : http {
  uses store: sql(ttl: 31536000s)
  uses locks: kv(ttl: 3600s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, locks.seen, locks.set, events.publish, files.put, files.get, uuid.new, Gateway.charge
    deny net, fs, exec
  }

  rules {
    unique Plan.code
  }

  contract {
    public op addPlan(code: string, name: string, priceCents: int, intervalDays: int) -> Plan {
      route: "POST /v1/plans"
      effects: store.insert, store.find, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: priceCents > 0
    }

    public op plans() -> list<Plan> {
      route: "GET /v1/plans"
      effects: store.find
      errors: none
      post: result != null
    }

    public op subscribe(planCode: string, customer: string, email: email, cardToken: string) -> Subscription {
      route: "POST /v1/subscriptions"
      effects: store.find, store.insert, uuid.new, events.publish
      errors: Invalid
      post: result != null
      on error Invalid: customer != null
    }

    public op subscription(id: SubId) -> Subscription {
      route: "GET /v1/subscriptions/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op invoices(id: SubId) -> list<Invoice> {
      route: "GET /v1/subscriptions/:id/invoices"
      effects: store.find
      errors: none
      post: result != null
    }

    public op invoice(id: InvoiceId) -> Invoice {
      route: "GET /v1/invoices/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op pay(id: InvoiceId) -> Invoice {
      route: "POST /v1/invoices/:id/pay"
      effects: store.fetch, store.update, events.publish
      errors: NotFound, Conflict
      post: result != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op receipt(id: InvoiceId) -> string {
      route: "GET /v1/invoices/:id/receipt"
      effects: store.fetch, files.get
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op reconcile() -> Ack {
      route: "POST /v1/admin/reconcile"
      effects: store.find, events.publish
      errors: none
      post: result != null
    }

    public op renew() -> Ack {
      route: "POST /v1/admin/renew"
      effects: store.find, store.insert, events.publish, uuid.new
      errors: none
      post: result != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.find
      errors: none
      post: result != null
    }

    job charge(invoiceId: InvoiceId, attempt: int) {
      on: events.charge
      retry: 1
      effects: store.fetch, store.update, files.put, events.publish, locks.seen, Gateway.charge
      errors: none
    }

    job dunning(invoiceId: InvoiceId, attempt: int) {
      on: events.dunning
      retry: 1
      effects: store.fetch, store.update, events.publish
      errors: none
    }
  }

  examples {
    example plan_then_subscribe {
      when {
        let plan = addPlan("pro", "Pro monthly", 9900, 30)
        let sub = subscribe("pro", "ACME", "billing@acme.test", "tok_ok")
      }
      then {
        plan.code == "pro"
        sub.planCode == "pro"
      }
    }

    example zero_price_is_rejected {
      when {
        let e = addPlan("free", "Free plan", 0, 30)
      }
      then {
        e is Invalid
      }
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Gateway -> endpoint(url: "http://localhost:9099")
  deploy docker
}
