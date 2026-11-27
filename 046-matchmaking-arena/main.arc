module matchmaking_arena @0.1.0 {
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

// A player's rating is the only thing matchmaking reads. Wins/losses are kept
// for the profile and for a sanity check that every game moves the ladder.
type ArenaPlayer = {
  id: string,
  name: string,
  rating: int,
  wins: int,
  losses: int,
  games: int,
  createdAt: datetime
}

// One queue entry per attempt. A player has at most one waiting ticket; the
// row is never deleted, so cancelled and matched attempts stay auditable.
type QueueTicket = {
  id: string,
  playerId: string,
  mode: string,
  rating: int,
  status: string,
  matchId: string,
  createdAt: datetime,
  updatedAt: datetime
}

// teamA/teamB are comma-separated player ids in display order. Members carry
// the authoritative per-player view; the match row is the state machine.
type ArenaMatch = {
  id: string,
  mode: string,
  status: string,
  teamA: string,
  teamB: string,
  ratingA: int,
  ratingB: int,
  winner: string,
  readyBy: datetime,
  archiveKey: string,
  createdAt: datetime,
  startedAt: string,
  finishedAt: string
}

type ArenaMember = {
  id: string,
  matchId: string,
  playerId: string,
  name: string,
  team: string,
  ready: bool,
  ratingBefore: int,
  ratingAfter: int,
  delta: int
}

// Inserted before ratings move. The unique matchId is the idempotency guard:
// two concurrent result calls cannot both settle the same match.
type MatchOutcome = {
  id: string,
  matchId: string,
  winner: string,
  createdAt: datetime
}

// A row, not a redis key: inserting it is the atomic "one waiting ticket per
// player" check, and deleting it releases the player after settlement.
type QueueLock = {
  id: string,
  playerId: string,
  ticketId: string,
  createdAt: datetime
}

// The matchmaker lock has an explicit expiry instead of a TTL: a crashed
// worker leaves the row behind, and the next pass steals it after 30 seconds.
type MatchGuard = {
  id: string,
  holder: string,
  expiresAt: datetime
}

type MatchView = {
  match: ArenaMatch,
  members: list<ArenaMember>
}

type ScanResult = {
  formed: int,
  waiting: int,
  matches: list<string>
}

type SweepResult = {
  expired: int,
  requeued: int
}

type ArchiveFile = {
  key: string,
  content: string,
  bytes: int
}

type ArenaStats = {
  players: int,
  waiting: int,
  ready: int,
  live: int,
  finished: int,
  archived: int
}

error Invalid
error Conflict
error NotFound

service Arena : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses live: stream
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.remove, store.find, store.count, events.publish, events.dead, live.publish, files.put, files.get, uuid.new
    deny net, fs, exec
  }

  rules {
    unique MatchOutcome.matchId
    unique ArenaMember.(matchId, playerId)
    unique QueueLock.playerId
  }

  contract {
    public op createPlayer(name: string, rating: int = 1200) -> ArenaPlayer {
      route: "POST /v1/players"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result.id != null
      on error Invalid: name != null
    }

    public op player(id: string) -> ArenaPlayer {
      route: "GET /v1/players/:id"
      effects: store.fetch
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    public op leaderboard(limit: int = 10) -> list<ArenaPlayer> {
      route: "GET /v1/leaderboard"
      effects: store.find
      errors: none
      post: result != null
    }

    // Enqueue is the only write a player makes to the queue. A row in
    // QueueLock is inserted before the ticket, so a double click cannot create
    // two waiting tickets even when the two requests interleave.
    public op enqueue(playerId: string, mode: string = "2v2") -> QueueTicket {
      route: "POST /v1/queue"
      effects: store.fetch, store.find, store.insert, store.remove, events.publish, uuid.new
      errors: NotFound, Invalid, Conflict
      post: result.id != null
      on error NotFound: playerId != null
      on error Invalid: mode != null
      on error Conflict: playerId != null
    }

    public op ticket(playerId: string) -> QueueTicket {
      route: "GET /v1/queue/:playerId"
      effects: store.find
      errors: NotFound
      post: result.id != null
      on error NotFound: playerId != null
    }

    public op cancelQueue(playerId: string) -> QueueTicket {
      route: "POST /v1/queue/:playerId/cancel"
      effects: store.find, store.update, store.remove
      errors: NotFound
      post: result.id != null
      on error NotFound: playerId != null
    }

    // Cron hook: a production timer calls it every few seconds. The enqueue
    // job already tries to form a match; scan is the safety net after a crash.
    public op scan(now: datetime) -> ScanResult {
      route: "POST /v1/match/scan"
      effects: store.find, store.fetch, store.insert, store.update, store.remove, store.count, events.publish, live.publish, uuid.new
      errors: none
      post: result.formed >= 0
    }

    public op matchInfo(id: string) -> MatchView {
      route: "GET /v1/matches/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.match.id != null
      on error NotFound: id != null
    }

    // Ready-check: all four must answer before the match goes live. A match
    // stuck in ready past readyBy is cancelled by sweep and requeued.
    public op ready(id: string, playerId: string) -> ArenaMatch {
      route: "POST /v1/matches/:id/ready"
      effects: store.fetch, store.find, store.update, live.publish
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op result(id: string, winner: string) -> ArenaMatch {
      route: "POST /v1/matches/:id/result"
      effects: store.fetch, store.find, store.insert, store.update, store.remove, events.publish, live.publish, uuid.new
      errors: NotFound, Invalid, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Invalid: winner != null
      on error Conflict: id != null
    }

    public op cancelMatch(id: string, reason: string = "cancelled") -> ArenaMatch {
      route: "POST /v1/matches/:id/cancel"
      effects: store.fetch, store.find, store.update, store.insert, events.publish, live.publish, uuid.new
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, store.fetch, store.update, store.insert, store.count, events.publish, live.publish, uuid.new
      errors: none
      post: result.expired >= 0
    }

    public op archiveInfo(id: string) -> ArchiveFile {
      route: "GET /v1/matches/:id/archive"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op stats() -> ArenaStats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result.players >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // Consumer 1: every enqueue wakes it. It claims the global matchmaking
    // guard, re-reads waiting tickets and forms at most one match per pass.
    // The message carries only the ticket id; the queue is the source of truth.
    job matchmake(ticketId: string) {
      on: events.matchmake
      retry: 2
      effects: store.find, store.fetch, store.insert, store.update, store.remove, events.publish, live.publish, uuid.new
      errors: none
    }

    // Consumer 2: builds the immutable result snapshot and writes it to S3.
    // A redelivery finds archiveKey and returns without a second object.
    job archive(matchId: string) {
      on: events.archive
      retry: 2
      effects: store.fetch, store.find, store.update, files.put, uuid.new
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind events -> redis(host: "redis", port: 6379)
  bind live -> websocket()
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  deploy docker
}
