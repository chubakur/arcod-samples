module warehouse_fulfillment @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.stream @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

// A SKU in the catalogue. onHand and reserved are counters maintained by the
// receiving, allocation and shipping paths; available = onHand - reserved.
// reorderPoint is the level at which the planner proposes a purchase.
type Product = {
  id: string,
  sku: string,
  name: string,
  reorderPoint: int,
  onHand: int,
  reserved: int,
  active: bool,
  createdAt: datetime
}

// A received lot. FEFO (first expired, first out) is decided by expiresAt,
// not by arrival order, so the same SKU can sit in several bins at once.
// remaining is what is still on the shelf: allocation decrements it, a
// cancellation puts units back, and the planner writes off an expired lot.
type Batch = {
  id: string,
  productId: string,
  code: string,
  bin: string,
  qty: int,
  remaining: int,
  status: string,
  expiresAt: datetime,
  receivedAt: datetime
}

// A customer order. status moves forward through the queue:
//   new -> allocated -> picking -> shipping -> shipped
// and sideways to backordered (not enough stock) or cancelled.
// clientRef is the idempotency key of the checkout.
type SalesOrder = {
  id: string,
  clientRef: string,
  customer: string,
  address: string,
  status: string,
  units: int,
  allocatedUnits: int,
  carrier: string,
  tracking: string,
  labelKey: string,
  createdAt: datetime,
  updatedAt: datetime
}

type OrderLine = {
  id: string,
  orderId: string,
  productId: string,
  sku: string,
  qty: int,
  allocated: int
}

// One held quantity of one batch for one line. The composite unique key makes
// a redelivered allocation message a no-op instead of a double reservation.
type Reservation = {
  id: string,
  orderId: string,
  lineId: string,
  productId: string,
  batchId: string,
  qty: int,
  status: string,
  createdAt: datetime
}

// A durable picking document in S3; the row is the index to it.
type PickList = {
  id: string,
  orderId: string,
  key: string,
  lines: int,
  units: int,
  createdAt: datetime
}

type Shipment = {
  id: string,
  orderId: string,
  carrier: string,
  tracking: string,
  labelKey: string,
  status: string,
  createdAt: datetime
}

// One open replenishment proposal per SKU. unique productId means the
// planner updates the existing row instead of stacking duplicates.
type Replenishment = {
  id: string,
  productId: string,
  sku: string,
  available: int,
  reorderPoint: int,
  suggestedQty: int,
  status: string,
  createdAt: datetime,
  updatedAt: datetime
}

// Append-only stock ledger: receipt, reserve, release, ship, writeoff.
type Movement = {
  id: string,
  productId: string,
  batchId: string,
  kind: string,
  qty: int,
  ref: string,
  createdAt: datetime
}

type OrderView = {
  order: SalesOrder,
  lines: list<OrderLine>,
  reservations: list<Reservation>,
  pickList: list<PickList>,
  shipments: list<Shipment>
}

type ProductView = {
  product: Product,
  batches: list<Batch>
}

type FileOut = {
  key: string,
  content: string,
  bytes: int
}

type Stats = {
  products: int,
  batchesOpen: int,
  orders: int,
  new: int,
  backordered: int,
  allocated: int,
  picking: int,
  shipping: int,
  shipped: int,
  cancelled: int,
  unitsOnHand: int,
  unitsReserved: int,
  openReplenishments: int
}

type PlannerResult = {
  expired: int,
  writtenOff: int,
  proposals: int,
  republished: int
}

type ShipReply = {
  tracking: string,
  label: string,
  service: string
}

type LineInput = {
  sku: string,
  qty: int
}

type RestockInput = {
  productId: string
}

// The carrier (3PL) API. The payload is an opaque JSON string so a carrier
// schema change does not become an Arcod type change.
external service Carrier : http {
  contract {
    op create(payload: string) -> ShipReply {
      route: "POST /v1/shipments"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Fulfillment : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses live: stream
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, store.aggregate, events.publish, events.dead, live.publish, files.put, files.get, Carrier.create, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Product.sku
    unique Batch.code
    unique SalesOrder.clientRef
    unique Reservation.(lineId, batchId)
    unique PickList.orderId
    unique Shipment.orderId
    unique Replenishment.productId
  }

  contract {
    // ---- catalogue -------------------------------------------------------

    public op createProduct(sku: string, name: string, reorderPoint: int = 0) -> Product {
      route: "POST /v1/products"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: sku != null
      on error Conflict: sku != null
    }

    public op products() -> list<Product> {
      route: "GET /v1/products"
      effects: store.find
      errors: none
      post: result != null
    }

    public op product(productId: string) -> ProductView {
      route: "GET /v1/products/:productId"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.product.id != null
      on error NotFound: productId != null
    }

    // ---- inbound ---------------------------------------------------------

    // Receiving a lot is an HTTP action because a physical delivery is an
    // external fact. The row and the ledger entry are written before the
    // answer; the restock consumer then wakes any backordered order.
    public op receive(productId: string, code: string, qty: int, expiresAt: datetime, bin: string = "A-01") -> Batch {
      route: "POST /v1/products/:productId/receipts"
      effects: store.fetch, store.find, store.insert, store.update, events.publish, live.publish, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: qty != null
      on error NotFound: productId != null
      on error Conflict: code != null
    }

    public op batches(productId: string = "", status: string = "") -> list<Batch> {
      route: "GET /v1/batches"
      effects: store.find
      errors: none
      post: result != null
    }

    // ---- orders ----------------------------------------------------------

    // The checkout call. It writes the order and its lines, then publishes
    // the id; stock is never touched inside the request. The same clientRef
    // returns the order that already exists.
    public op createOrder(clientRef: string, customer: string, address: string, lines: list<LineInput>) -> SalesOrder {
      route: "POST /v1/orders"
      effects: store.find, store.insert, events.publish, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: lines != null
      on error NotFound: clientRef != null
      on error Conflict: clientRef != null
    }

    public op orders(status: string = "", limit: int = 50) -> list<SalesOrder> {
      route: "GET /v1/orders"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    public op order(orderId: string) -> OrderView {
      route: "GET /v1/orders/:orderId"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.order.id != null
      on error NotFound: orderId != null
    }

    // The picking document the pickList consumer wrote: lines with bin and
    // batch, ready for a picker.
    public op picklist(orderId: string) -> FileOut {
      route: "GET /v1/orders/:orderId/picklist"
      effects: store.fetch, store.find, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: orderId != null
    }

    // Shipping is asynchronous because the carrier is: the request hands the
    // order to the shipOrder consumer and answers 200. A second ship while
    // the first is in flight is a conflict.
    public op ship(orderId: string, carrier: string = "post") -> SalesOrder {
      route: "POST /v1/orders/:orderId/ship"
      status: 200
      effects: store.fetch, store.update, events.publish
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: orderId != null
      on error Conflict: orderId != null
    }

    // The label is an object in S3, not a field: the terminal prints it.
    public op label(orderId: string) -> FileOut {
      route: "GET /v1/orders/:orderId/label"
      effects: store.fetch, store.find, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: orderId != null
    }

    // Cancellation before handover returns the reserved units to their lots.
    // After shipped there is nothing to return; after shipping the parcel is
    // already with the carrier.
    public op cancel(orderId: string) -> SalesOrder {
      route: "POST /v1/orders/:orderId/cancel"
      status: 200
      effects: store.fetch, store.find, store.update, events.publish, live.publish
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: orderId != null
      on error Conflict: orderId != null
    }

    // ---- planning --------------------------------------------------------

    // No cron for jobs (#12): an external runner calls the planner with an
    // explicit instant. It writes off expired lots, proposes replenishment
    // for SKUs at or below their reorder point and retries backordered
    // orders that now have stock.
    public op runPlanner(now: datetime) -> PlannerResult {
      route: "POST /v1/planner/run"
      effects: store.find, store.fetch, store.insert, store.update, events.publish, uuid.new
      errors: Invalid
      post: result.expired >= 0
      on error Invalid: now != null
    }

    public op replenishments(status: string = "open") -> list<Replenishment> {
      route: "GET /v1/replenishments"
      effects: store.find
      errors: none
      post: result != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.aggregate
      errors: none
      post: result.orders >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // ---- consumers -------------------------------------------------------

    // Consumer 1: reserve stock FEFO across lots, move the order to
    // allocated (full) or backordered (partial), then queue picking.
    job allocate(orderId: string) {
      on: events.allocate
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, events.publish, live.publish, uuid.new
      errors: none
    }

    // Consumer 2: write the picking document to S3 and index it. The order
    // moves to picking only after the document exists.
    job buildPick(orderId: string) {
      on: events.pick
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, files.put, live.publish, uuid.new
      errors: none
    }

    // Consumer 3: call the carrier, write the label to S3, move held
    // reservations to shipped and decrement on-hand. A carrier outage is
    // retried and then dead-lettered; the order stays shipping.
    job shipOrder(orderId: string) {
      on: events.ship
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, files.put, live.publish, Carrier.create, uuid.new
      errors: none
    }

    // Consumer 4: a receipt may unblock backordered orders for that SKU.
    // It re-publishes them; allocate decides again with fresh stock.
    job restock(productId: string) {
      on: events.restock
      retry: 2
      effects: store.find, events.publish
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind live -> websocket()
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Carrier -> endpoint(url: "http://localhost:9094")
  deploy docker
}
