module shop @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.blob @1
use capability arcod.std.queue @1
use capability arcod.std.ids @1

type ProductId = uuid
type OrderId = uuid
type Money = int
type Sku = string

type Product = {
  id: ProductId,
  sku: Sku,
  title: string,
  price: Money,
  stock: int,
  createdAt: datetime
}

type Order = {
  id: OrderId,
  product: ProductId,
  sku: Sku,
  qty: int,
  amount: Money,
  status: string,
  paymentRef: string,
  createdAt: datetime,
  packedAt: datetime?
}

type Charge = { order: OrderId, amount: Money, token: string }
type Auth = { ref: string, approved: bool }
type Invoice = { id: OrderId, sku: Sku, qty: int, amount: Money, status: string, at: datetime }

// Внешний платёжный шлюз: описан только вызов, тела и контейнера у него нет.
external service Gateway : http {
  contract {
    op authorize(charge: Charge) -> Auth {
      route: "POST /v1/charges"
    }
  }
}

error Invalid
error NotFound
error Conflict
error Rejected
error Unavailable

service Shop : http {
  uses store: sql(ttl: 31536000s, consistency: strong)
  uses uuid: ids
  uses invoices: blob
  uses events: queue

  effects {
    allow store.insert, store.fetch, store.update, uuid.new, invoices.put, invoices.get, events.publish, Gateway.authorize
    deny net, fs, exec
  }

  rules {
    unique Product.sku
  }

  contract {
    public op addProduct(sku: string, title: string, price: Money, stock: int) -> Product {
      route: "POST /v1/products"
      effects: store.insert, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: title != null
      on error Conflict: sku != null
    }

    public op getProduct(id: ProductId) -> Product {
      route: "GET /v1/products/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op placeOrder(product: ProductId, qty: int, token: string) -> Order {
      route: "POST /v1/orders"
      effects: store.fetch, store.insert, store.update, uuid.new, Gateway.authorize, events.publish
      errors: Invalid, NotFound, Conflict, Rejected, Unavailable
      post: result != null
      on error Invalid: qty != null
      on error NotFound: product != null
      on error Conflict: product != null
      on error Rejected: token != null
      on error Unavailable: product != null
    }

    public op getOrder(id: OrderId) -> Order {
      route: "GET /v1/orders/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op getInvoice(id: OrderId) -> Invoice {
      route: "GET /v1/orders/:id/invoice"
      effects: store.fetch, invoices.get
      errors: NotFound, Conflict
      post: result != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    job pack(orderId: OrderId) {
      on: events.pack
      retry: 2
      effects: store.fetch, store.update, invoices.put
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind invoices -> s3(host: "s3", port: 9000)
  bind events -> rabbitmq(host: "mq", port: 5672)
  bind uuid -> local
  bind Gateway -> endpoint(url: "http://localhost:9099")
  deploy docker
}
