module collab_board @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-18"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1
use capability arcod.std.stream @1

type RoomId = uuid
type ShapeId = uuid

type Room = {
  id: RoomId,
  name: string,
  createdAt: datetime,
  revision: int
}

// The merge metadata is part of the contract: every mutable field carries the
// Lamport clock and the client that wrote it. A client can replay the same
// board from any replica and compute the same winner.
type Shape = {
  id: ShapeId,
  roomId: RoomId,
  kind: string,
  x: int,
  y: int,
  w: int,
  h: int,
  color: string,
  deleted: bool,
  revision: int,
  xClock: int,
  yClock: int,
  wClock: int,
  hClock: int,
  colorClock: int,
  delClock: int,
  xBy: string,
  yBy: string,
  wBy: string,
  hBy: string,
  colorBy: string,
  delBy: string
}

type Op = {
  id: uuid,
  roomId: RoomId,
  seq: int,
  clientId: string,
  shapeId: ShapeId,
  kind: string,
  x: int?,
  y: int?,
  w: int?,
  h: int?,
  color: string?,
  lamport: int,
  at: datetime
}

type Board = {
  roomId: RoomId,
  revision: int,
  shapes: list<Shape>
}

type ApplyResult = {
  op: Op,
  revision: int,
  duplicate: bool
}

error Invalid
error NotFound

service CollabBoard : http {
  uses store: kv(ttl: 2592000s)
  uses uuid: ids
  uses stream: stream

  effects {
    allow store.insert, store.find, store.update, uuid.new, stream.publish
  }

  contract {
    public op createRoom(name: string) -> Room {
      route: "POST /v1/rooms"
      effects: store.insert, uuid.new
      errors: Invalid
      post: result != null
      on error Invalid: name != null
    }

    public op getRoom(id: RoomId) -> Room {
      route: "GET /v1/rooms/:id"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op listRooms(limit: int = 50) -> list<Room> {
      route: "GET /v1/rooms"
      effects: store.find
      post: result != null
    }

    public op applyOp(
      roomId: RoomId,
      opId: uuid,
      clientId: string,
      shapeId: ShapeId,
      kind: string,
      lamport: int,
      x: int?,
      y: int?,
      w: int?,
      h: int?,
      color: string?
    ) -> ApplyResult {
      route: "POST /v1/rooms/:roomId/ops"
      effects: store.find, store.insert, store.update, stream.publish
      errors: Invalid, NotFound
      post: result != null
      on error Invalid: clientId != null
      on error NotFound: roomId != null
    }

    public op board(roomId: RoomId) -> Board {
      route: "GET /v1/rooms/:roomId/board"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: roomId != null
    }

    public op listOps(roomId: RoomId, after: int = 0, limit: int = 200) -> list<Op> {
      route: "GET /v1/rooms/:roomId/ops"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: roomId != null
    }
  }

  examples {
    example board_roundtrip {
      when {
        let r = createRoom("demo")
        let op = applyOp(r.id, uuid("00000000-0000-4000-8000-000000000901"), "alice", uuid("00000000-0000-4000-8000-000000000902"), "add", 1, 10, 20, 100, 50, "#fff")
      }
      then {
        getRoom(r.id).name == "demo"
        board(r.id).revision == 1
        listOps(r.id, 0, 10) != null
        listRooms(10) != null
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
