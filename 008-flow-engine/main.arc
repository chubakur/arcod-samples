module flow_engine @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-19"
  }
}

use capability arcod.std.kv @1
use capability arcod.std.ids @1

// A durable workflow engine whose definitions are data.
//
// Arcod can describe a workflow in the contract (workflow/saga blocks), but a
// scheduler for *user-supplied* definitions cannot: the steps arrive over
// HTTP, so the engine has to keep them as records, decide what is ready,
// persist retries and timers, and compensate in reverse order. That is the
// whole point of this example: the state machine lives in data, the contract
// only describes the API and the effects it may touch.

// One step of a user-supplied definition. after names a single dependency;
// an empty string means "ready at start". action is one of ok, set, sleep,
// flaky, fail. key/value feed the set action; value is rendered with
// {{input}} and {{vars.name}}. retry is the number of *extra* attempts,
// backoffMs doubles on every attempt. compensate is the action run when the
// whole run is rolled back ("" skips the step).
type Step = {
  name: string,
  action: string,
  after: string,
  key: string,
  value: string,
  delayMs: int,
  retry: int,
  backoffMs: int,
  failFirst: int,
  compensate: string
}

type StepView = {
  name: string,
  kind: string,
  status: string,
  attempts: int,
  dueAt: datetime?,
  output: string,
  error: string
}

type WorkflowView = {
  name: string,
  version: int,
  steps: list<Step>,
  createdAt: datetime
}

type RunView = {
  id: string,
  workflow: string,
  version: int,
  status: string,
  input: string,
  vars: string,
  step: string,
  attempts: int,
  nextAt: datetime?,
  error: string,
  steps: list<StepView>,
  createdAt: datetime,
  updatedAt: datetime
}

type RunPage = {
  items: list<RunView>,
  next: string?
}

type ScheduleView = {
  name: string,
  workflow: string,
  everySeconds: int,
  nextAt: datetime,
  enabled: bool
}

type TickItem = {
  run: string,
  workflow: string,
  advanced: int,
  state: string
}

type TickResult = {
  now: datetime,
  claimed: int,
  advanced: int,
  completed: int,
  failed: int,
  spawned: int,
  items: list<TickItem>
}

type WorkflowRec = {
  id: string,
  name: string,
  version: int,
  steps: string,
  createdAt: datetime
}

type RunRec = {
  id: string,
  workflow: string,
  version: int,
  status: string,
  input: string,
  vars: string,
  step: string,
  attempts: int,
  nextAt: datetime?,
  error: string,
  generation: int,
  createdAt: datetime,
  updatedAt: datetime
}

type StepState = {
  id: string,
  runId: string,
  name: string,
  kind: string,
  status: string,
  attempts: int,
  dueAt: datetime?,
  output: string,
  error: string,
  order: int
}

type Claim = {
  id: string,
  slot: string,
  runId: string,
  generation: int,
  at: datetime
}

type ScheduleRec = {
  name: string,
  workflow: string,
  everySeconds: int,
  nextAt: datetime,
  enabled: bool
}

type Health = {
  ok: bool,
  workflows: int,
  runs: int
}

error Invalid
error NotFound
error Conflict

service Flows : http {
  uses store: kv
  uses uuid: ids

  effects {
    allow store.get, store.set, store.insert, store.find, store.fetch, store.update, store.remove, uuid.new
    deny net, fs, exec
  }

  rules {
    // One claim per run per generation: the insert is the only atomic
    // operation the body has, so it doubles as the lease guard. Two ticks
    // that read the same run cannot both insert the same slot.
    unique Claim.slot
    unique ScheduleRec.name
  }

  contract {
    // A definition is immutable once accepted; a changed graph is a new name.
    public op createWorkflow(name: string, steps: list<Step>) -> WorkflowView {
      route: "POST /v1/workflows"
      effects: store.insert, store.find
      errors: Invalid, Conflict
      post: result.name != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op listWorkflows() -> list<WorkflowView> {
      route: "GET /v1/workflows"
      effects: store.find
      post: result != null
    }

    public op getWorkflow(name: string) -> WorkflowView {
      route: "GET /v1/workflows/:name"
      effects: store.fetch
      errors: NotFound
      post: result.name != null
      on error NotFound: name != null
    }

    // A run pins the definition version at the moment it starts. Steps are
    // seeded as records; nothing runs until a tick claims the run.
    public op createRun(workflow: string, input: string = "") -> RunView {
      route: "POST /v1/runs"
      effects: store.fetch, store.find, store.insert, uuid.new
      errors: Invalid, NotFound
      post: result.id != null
      on error Invalid: workflow != null
      on error NotFound: workflow != null
    }

    public op listRuns(status: string = "", limit: int = 20) -> RunPage {
      route: "GET /v1/runs"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: status != null
    }

    public op getRun(id: string) -> RunView {
      route: "GET /v1/runs/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.id != null
      on error NotFound: id != null
    }

    // Cancelling is a compensation, not a flag: every completed step is
    // rolled back before the run reports cancelled.
    public op cancelRun(id: string) -> RunView {
      route: "POST /v1/runs/:id/cancel"
      effects: store.fetch, store.find, store.insert, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    // The clock lives outside the service. A tick spawns due schedules,
    // claims runs whose nextAt has passed, and advances each by one wave.
    public op tick(limit: int = 20) -> TickResult {
      route: "POST /v1/ticks"
      effects: store.find, store.fetch, store.insert, store.update, uuid.new
      errors: Invalid
      post: result.now != null
      on error Invalid: limit > 0
    }

    public op createSchedule(name: string, workflow: string, everySeconds: int) -> ScheduleView {
      route: "POST /v1/schedules"
      effects: store.fetch, store.insert
      errors: Invalid, NotFound, Conflict
      post: result.name != null
      on error Invalid: name != null
      on error NotFound: workflow != null
      on error Conflict: name != null
    }

    public op listSchedules() -> list<ScheduleView> {
      route: "GET /v1/schedules"
      effects: store.find
      post: result != null
    }

    public op health() -> Health {
      route: "GET /v1/health"
      effects: store.find
      post: result.ok == true
    }
  }
}

environment dev {
  bind store -> redis(host: "kv", port: 6379)
  bind uuid -> local
  deploy docker
}
