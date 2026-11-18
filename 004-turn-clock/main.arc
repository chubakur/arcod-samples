module turn_clock @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-18"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1
use capability arcod.std.stream @1

// The board is nine characters: '.', 'x' for player one, 'o' for player two.
// A string keeps the merge rule trivial and the diff readable in a replay.
type RoomId = uuid

type Player = {
  id: string,
  name: string,
  bankMs: int,
  timeouts: int,
  moves: int
}

// A seat token is the only secret in the model: it lives outside Room so that
// reading a room can never leak somebody else's right to move.
type Seat = {
  id: string,
  roomId: RoomId,
  playerId: string,
  role: string
}

type Room = {
  id: RoomId,
  code: string,
  name: string,
  status: string,
  board: string,
  p1: Player,
  p2: Player?,
  turn: string,
  seq: int,
  turnMs: int,
  bankMs: int,
  createdAt: datetime,
  turnStartedAt: datetime?,
  deadline: datetime?,
  winner: string?,
  reason: string?
}

type Event = {
  id: uuid,
  roomId: RoomId,
  seq: int,
  kind: string,
  playerId: string,
  cell: int,
  moveId: string,
  at: datetime
}

type Session = {
  roomId: RoomId,
  playerId: string,
  token: string,
  role: string,
  room: Room
}

type TickResult = {
  seq: int,
  accepted: bool,
  duplicate: bool,
  timeouts: int,
  note: string,
  room: Room,
  events: list<Event>,
  serverTime: datetime
}

type Replay = {
  roomId: RoomId,
  moves: int,
  board: string,
  winner: string?,
  consistent: bool
}

error NotFound
error Forbidden
error Invalid

service TurnClock : http {
  uses store: kv(ttl: 604800s)
  uses uuid: ids
  uses stream: stream

  effects {
    allow store.insert, store.find, store.update, uuid.new, stream.publish
  }

  contract {
    // The host opens a room and gets a short code plus a seat token. The token
    // is the credential: the same call returns it once and never again.
    public op createRoom(
      name: string,
      player: string,
      turnSeconds: int = 30,
      bankSeconds: int = 120
    ) -> Session {
      route: "POST /v1/rooms"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    // A second player joins by code. A wrong code never reveals whether the
    // room exists. A full room does not fail: the caller becomes a spectator
    // and can still follow the stream and the event log.
    public op join(roomId: RoomId, code: string, name: string) -> Session {
      route: "POST /v1/rooms/:roomId/join"
      effects: store.find, store.insert, store.update, uuid.new, stream.publish
      errors: NotFound, Forbidden, Invalid
      post: result != null
      on error NotFound: roomId != null
      on error Forbidden: code != null
      on error Invalid: name != null
    }

    // Every interaction is a tick: it first settles all expired clocks, then
    // applies the request, then returns the events the caller has not seen.
    // kind is sync | move | resign.
    public op tick(
      roomId: RoomId,
      token: string = "",
      kind: string = "sync",
      cell: int = -1,
      moveId: string = "",
      sinceSeq: int = 0
    ) -> TickResult {
      route: "POST /v1/rooms/:roomId/tick"
      effects: store.find, store.insert, store.update, uuid.new, stream.publish
      errors: NotFound, Forbidden, Invalid
      post: result != null
      on error NotFound: roomId != null
      on error Forbidden: token != null
      on error Invalid: kind != null
    }

    public op events(roomId: RoomId, after: int = 0, limit: int = 200) -> list<Event> {
      route: "GET /v1/rooms/:roomId/events"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: roomId != null
    }

    // A pure projection: fold the move events again and compare with the board
    // the room carries. If they differ, the log and the snapshot disagree.
    public op replay(roomId: RoomId) -> Replay {
      route: "GET /v1/rooms/:roomId/replay"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: roomId != null
    }

    public op listRooms(limit: int = 20) -> list<Room> {
      route: "GET /v1/rooms"
      effects: store.find
      post: result != null
    }
  }

  examples {
    example duel_flow {
      when {
        let s = createRoom("demo", "alice", 30, 60)
        let j = join(s.roomId, s.room.code, "bob")
        let t = tick(s.roomId, s.token, "move", 4, uuid("00000000-0000-4000-8000-000000000301"), 0)
      }
      then {
        j.role == "p2"
        t.accepted == true
        t.room.board == "....x...."
        t.room.turn == "p2"
        events(s.roomId, 0, 10) != null
        replay(s.roomId).consistent == true
        listRooms(5) != null
      }
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  bind stream -> websocket()
  deploy docker
}
