module fence_locks @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-18"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1

// A lease is the right to touch one named resource for a while. The token is
// the credential; the fence is the number the resource has to remember. Two
// different things, never in the same record that a client can read.

type LockId = uuid
type ResourceId = string(min: 1, max: 120)

type Lease = {
  id: LockId,
  name: string,
  owner: string,
  token: string,
  fence: int,
  ttlMs: int,
  renewals: int,
  acquiredAt: datetime,
  renewedAt: datetime,
  expiresAt: datetime
}

// What the outside world sees: a lease without its token.
type LeaseView = {
  id: LockId,
  name: string,
  owner: string,
  fence: int,
  ttlMs: int,
  renewals: int,
  acquiredAt: datetime,
  renewedAt: datetime,
  expiresAt: datetime
}

// The allocation ledger. 'slot' is the string `name#fence`; the unique claim
// on it makes "take the next number" an atomic insert instead of a
// read-modify-write. Uniqueness is the only compare-and-swap the store has.
type Fence = {
  id: uuid,
  name: string,
  slot: string,
  fence: int,
  owner: string,
  at: datetime
}

// The audit trail. Written after the fact, so a burned number never looks
// like a grant: acquired | released | expired.
type Trace = {
  id: uuid,
  name: string,
  fence: int,
  kind: string,
  owner: string,
  at: datetime
}

type Granted = {
  token: string,
  lease: LeaseView
}

type LockState = {
  name: string,
  held: bool,
  fence: int,
  lease: LeaseView?
}

// A resource that only accepts writes carrying the newest fence. This is the
// consumer side of the protocol: it is what makes a paused holder harmless.
type Guarded = {
  id: ResourceId,
  resource: ResourceId,
  fence: int,
  value: string,
  writer: string,
  writes: int,
  appliedAt: datetime
}

error NotFound
error Forbidden
error Invalid
error Conflict

service FenceLocks : http {
  uses store: kv(ttl: 604800s, consistency: strong)
  uses uuid: ids

  effects {
    allow store.find, store.insert, store.update, store.remove, store.fetch, uuid.new
    deny net, fs, exec
  }

  rules {
    // Two claims do the work a compare-and-swap would do elsewhere.
    unique Fence.slot
    unique Lease.name
  }

  contract {
    // Take the lock. A live lease answers 409 and never says who holds it, so
    // a caller cannot turn a failed acquisition into a directory lookup.
    // An expired lease is removed by id, never by name: a rival that already
    // replaced it must not be deleted by our late cleanup.
    public op acquire(
      name: string,
      owner: string,
      ttlMs: int = 15000
    ) -> Granted {
      route: "POST /v1/locks/:name/acquire"
      effects: store.find, store.insert, store.remove, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    // All-or-nothing over a set of locks. Names are deduplicated and sorted
    // before the first grant, so two clients never wait on each other in the
    // opposite order: a deadlock is impossible by construction, not by luck.
    public op acquireAll(
      names: list<string>,
      owner: string,
      ttlMs: int = 15000
    ) -> list<Granted> {
      route: "POST /v1/locks/acquire"
      effects: store.find, store.insert, store.remove, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: names != null
      on error Conflict: names != null
    }

    // Extend a lease you still hold. The ttl is remembered per lease, so a
    // renewal without an argument keeps the original window.
    public op renew(name: string, token: string, ttlMs: int = 0) -> LeaseView {
      route: "POST /v1/locks/:name/renew"
      effects: store.find, store.update, store.remove, uuid.new
      errors: NotFound, Forbidden, Invalid
      post: result != null
      on error NotFound: name != null
      on error Forbidden: token != null
    }

    // Give it back early. The fence stays allocated: numbers are never reused.
    public op release(name: string, token: string) -> LeaseView {
      route: "POST /v1/locks/:name/release"
      effects: store.find, store.remove, uuid.new
      errors: NotFound, Forbidden
      post: result != null
      on error NotFound: name != null
      on error Forbidden: token != null
    }

    public op state(name: string) -> LockState {
      route: "GET /v1/locks/:name"
      effects: store.find, store.remove, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    public op locks(prefix: string = "", limit: int = 50) -> list<LeaseView> {
      route: "GET /v1/locks"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    public op history(name: string, limit: int = 20) -> list<Trace> {
      route: "GET /v1/locks/:name/history"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    // The consumer side. A write arrives with a fence; a fence older than the
    // last one applied is rejected even if its holder still believes it owns
    // the lock. The same fence is only a replay of the same payload. This is
    // the whole point of the number.
    public op guard(
      resource: ResourceId,
      fence: int,
      value: string,
      writer: string = ""
    ) -> Guarded {
      route: "POST /v1/resources/:resource/write"
      effects: store.fetch, store.insert, store.update
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: resource != null
      on error Conflict: resource != null
    }
  }

  examples {
    example grant_then_escalate {
      when {
        let a = acquire("orders/42", "worker-a", 30000)
      }
      then {
        a.lease.fence == 1
        release("orders/42", a.token).fence == 1
        acquire("orders/42", "worker-b", 30000).lease.fence == 2
      }
    }

    example stale_writer_is_stopped {
      when {
        let a = acquire("ledger", "worker-a", 30000)
        let w = guard("ledger", a.lease.fence, "v1", "worker-a")
        release("ledger", a.token)
        let b = acquire("ledger", "worker-b", 30000)
      }
      then {
        w.writes == 1
        guard("ledger", a.lease.fence, "v2", "worker-a") is Conflict
        guard("ledger", b.lease.fence, "v2", "worker-b").writes == 2
      }
    }

    example renewal_extends_the_window {
      when {
        let a = acquire("cache/warm", "worker-a", 3000)
        let r = renew("cache/warm", a.token, 60000)
      }
      then {
        r.renewals == 1
        state("cache/warm").held == true
      }
    }

    example listing_and_history {
      when {
        let a = acquire("reports", "worker-a", 30000)
        let b = acquire("reports/2026", "worker-b", 30000)
      }
      then {
        locks("reports", 10) != null
        history("reports", 10) != null
        history("reports", 0) is Invalid
      }
    }

    example batch_takes_a_set {
      when {
        let set = acquireAll(["orders/2", "orders/1"], "batch", 30000)
      }
      then {
        set != null
        acquire("orders/1", "worker-a", 30000) is Conflict
      }
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  deploy docker
}
