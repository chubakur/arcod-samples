module expense_splitter @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-18"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1

type GroupId = uuid
type Amount = int
type Group = {
  id: GroupId,
  name: string,
  members: list<string>,
  currency: string,
  createdAt: datetime
}
type Expense = {
  id: uuid,
  payer: string,
  amount: Amount,
  participants: list<string>,
  note: string?,
  at: datetime
}
type Balance = { member: string, paid: Amount, owed: Amount, net: Amount }
type Ledger = { group: Group, expenses: list<Expense>, balances: list<Balance> }

error Invalid
error NotFound

service ExpenseSplitter : http {
  uses store: kv(ttl: 31536000s, consistency: strong)
  uses uuid: ids

  effects {
    allow store.get, store.set, uuid.new
  }

  contract {
    public op createGroup(name: string, members: list<string>, currency: string) -> Group {
      route: "POST /v1/groups"
      effects: store.set, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    public op addExpense(groupId: GroupId, payer: string, amount: Amount, participants: list<string>, note: string?) -> Expense {
      route: "POST /v1/groups/:groupId/expenses"
      effects: store.get, store.set, uuid.new
      errors: Invalid, NotFound
      post: result != null
      on error NotFound: groupId != null
      on error Invalid: amount != null
    }

    public op getLedger(groupId: GroupId) -> Ledger {
      route: "GET /v1/groups/:groupId/ledger"
      effects: store.get
      errors: NotFound
      post: result != null
      on error NotFound: groupId != null
    }
  }

}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  deploy docker
}
