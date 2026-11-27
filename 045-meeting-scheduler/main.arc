module meeting_scheduler @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

// Booking windows are kept in UTC; every human-facing label is rendered in the
// timezone of the person reading it. Hosts define working hours in their own
// timezone, guests ask for slots in theirs, and the scheduler never stores a
// wall-clock time without the zone it belongs to.
error Invalid
error NotFound
error Conflict

type Host = {
  id: string,
  name: string,
  email: string,
  timezone: string,
  workStart: string,
  workEnd: string,
  createdAt: datetime
}

type Booking = {
  id: string,
  hostId: string,
  hostName: string,
  guestEmail: string,
  guestTimezone: string,
  startsAt: datetime,
  endsAt: datetime,
  durationMin: int,
  status: string,
  inviteKey: string,
  hostLocal: string,
  guestLocal: string,
  createdAt: datetime
}

type Slot = {
  startsAt: datetime,
  endsAt: datetime,
  hostLocal: string,
  guestLocal: string
}

// One row per 15-minute cell a booking occupies. The unique key is the
// concurrency guard: two guests racing for the same cell cannot both insert.
type Hold = {
  id: string,
  key: string,
  hostId: string,
  bookingId: string,
  cell: datetime
}

type Invite = {
  id: string,
  key: string,
  bookingId: string,
  kind: string,
  email: string,
  status: string,
  icsKey: string,
  createdAt: datetime
}

type Reminder = {
  id: string,
  bookingId: string,
  dueAt: datetime,
  status: string
}

type InviteFile = {
  key: string,
  kind: string,
  status: string,
  body: string
}

type Dispatch = {
  due: int,
  queued: int
}

type Stats = {
  hosts: int,
  bookings: int,
  cancelled: int,
  invites: int,
  pendingInvites: int,
  reminders: int
}

service Scheduler : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.remove, store.find, store.count, events.publish, files.put, files.get, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Host.email
    unique Hold.key
    unique Invite.key
  }

  contract {
    public op addHost(name: string, email: string, timezone: string, workStart: string, workEnd: string) -> Host {
      route: "POST /v1/hosts"
      effects: store.insert, store.find, uuid.new
      errors: Invalid, Conflict
      post: result != null
      on error Invalid: name != null
      on error Conflict: email != null
    }

    public op slots(hostId: string, date: string, tz: string, dur: int) -> list<Slot> {
      route: "GET /v1/hosts/:hostId/slots"
      effects: store.fetch, store.find
      errors: NotFound, Invalid
      post: result != null
      on error NotFound: hostId != null
      on error Invalid: date != null
    }

    public op book(hostId: string, guestEmail: string, guestTimezone: string, startsAt: string, dur: int) -> Booking {
      route: "POST /v1/bookings"
      effects: store.fetch, store.insert, store.update, store.remove, store.find, events.publish, uuid.new
      errors: NotFound, Invalid, Conflict
      post: result != null
      on error NotFound: hostId != null
      on error Invalid: dur > 0
      on error Conflict: startsAt != null
    }

    public op cancel(id: string) -> Booking {
      route: "POST /v1/bookings/:id/cancel"
      effects: store.fetch, store.update, store.remove, store.find, events.publish, uuid.new
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op booking(id: string) -> Booking {
      route: "GET /v1/bookings/:id"
      effects: store.fetch
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op invite(id: string) -> InviteFile {
      route: "GET /v1/bookings/:id/invite"
      effects: store.find, files.get
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    // Cron hook. In production a workflow timer calls it every minute; the op
    // only claims due reminders and enqueues them, it never sends inline.
    public op dispatch(now: string) -> Dispatch {
      route: "POST /v1/reminders/dispatch"
      effects: store.find, store.update, events.publish
      errors: none
      post: result != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result != null
    }

    // Consumer 1: build the .ics, put it in S3, mark the invite delivered.
    job deliver(inviteId: string) {
      on: events.invite
      retry: 3
      effects: store.fetch, store.update, files.put, files.get
      errors: none
    }

    // Consumer 2: the same pipeline for a reminder that came due.
    job remind(reminderId: string) {
      on: events.reminder
      retry: 2
      effects: store.fetch, store.update, files.put
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "redis", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  deploy docker
}
