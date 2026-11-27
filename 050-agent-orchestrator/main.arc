module agent_orchestrator @0.1.0 {
  meta {
    owner: "@genry"
    status: draft
    since: "2026-11-27"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.llm @1
use capability arcod.std.ids @1

// An agent is a prompt plus a closed list of tools it may call. The budget is
// enforced by the runner, not by the model: a model that keeps asking for
// tools is stopped when the estimated spend crosses tokenBudget.
type Agent = {
  id: string,
  name: string,
  systemPrompt: string,
  tools: string,
  maxSteps: int,
  tokenBudget: int,
  pricePer1kTokens: int,
  pricePerToolCall: int,
  createdAt: datetime
}

// A run is the unit of work. status: queued | running | succeeded | failed |
// budget_exceeded | cancelled. cancelRequested is sticky: the runner checks it
// between steps and the cancel operation never blocks on the runner.
type Run = {
  id: string,
  agentId: string,
  clientRef: string,
  input: string,
  status: string,
  steps: int,
  tokens: int,
  toolCalls: int,
  answer: string,
  error: string,
  cancelRequested: bool,
  createdAt: datetime,
  startedAt: datetime?,
  finishedAt: datetime?,
  traceKey: string
}

// One model turn or one tool call, appended as the run progresses. kind:
// tool | final | denied | error. args/output are JSON strings: the row is the
// durable transcript the runner rebuilds after a redelivery.
type Step = {
  id: string,
  runId: string,
  seq: int,
  kind: string,
  tool: string,
  args: string,
  output: string,
  tokens: int,
  at: datetime
}

// One billable run, written by the invoice consumer. unique runId makes a
// redelivered event free: the second attempt finds the row and stops.
type Usage = {
  id: string,
  runId: string,
  agentId: string,
  tokens: int,
  toolCalls: int,
  amount: int,
  receiptKey: string,
  createdAt: datetime
}

type RunView = {
  run: Run,
  steps: list<Step>
}

type TraceFile = {
  key: string,
  content: string,
  bytes: int
}

type Stats = {
  runs: int,
  queued: int,
  running: int,
  succeeded: int,
  failed: int,
  budgetExceeded: int,
  cancelled: int,
  tokens: int,
  toolCalls: int,
  amount: int
}

type SweepResult = {
  stale: int,
  invoiced: int
}

type ToolReply = {
  ok: bool,
  output: string
}

// The tool sandbox. In this sample it is a small HTTP service; in production
// it is whichever internal API the agent is allowed to touch.
external service Tools : http {
  contract {
    op call(name: string, args: string) -> ToolReply {
      route: "POST /v1/tools/call"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Orchestrator : http {
  uses store: sql(ttl: 31536000s)
  uses events: queue
  uses files: blob
  uses model: llm
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, store.aggregate, events.publish, events.dead, files.put, files.get, model.chat, Tools.call, uuid.new
    deny net, fs, exec
  }

  rules {
    unique Agent.name
    unique Run.clientRef
    unique Usage.runId
  }

  contract {
    // ---- agents ----------------------------------------------------------

    // tools is a comma-separated allow-list. A tool the model invents is a
    // failed run, not a call: the runner checks the list before io.remote.
    public op createAgent(name: string, systemPrompt: string, tools: string, maxSteps: int = 6, tokenBudget: int = 8000, pricePer1kTokens: int = 10, pricePerToolCall: int = 2) -> Agent {
      route: "POST /v1/agents"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.id != null
      on error Invalid: name != null
      on error Conflict: name != null
    }

    public op agents() -> list<Agent> {
      route: "GET /v1/agents"
      effects: store.find
      errors: none
      post: result != null
    }

    // ---- runs ------------------------------------------------------------

    // clientRef makes the call idempotent: the same reference returns the run
    // that already exists instead of starting a second one. An empty
    // reference always starts a new run.
    public op startRun(agentId: string, input: string, clientRef: string = "") -> Run {
      route: "POST /v1/agents/:agentId/runs"
      effects: store.fetch, store.find, store.insert, events.publish, uuid.new
      errors: Invalid, NotFound, Conflict
      post: result.id != null
      on error Invalid: input != null
      on error NotFound: agentId != null
      on error Conflict: clientRef != null
    }

    public op runs(status: string = "", limit: int = 50) -> list<Run> {
      route: "GET /v1/runs"
      effects: store.find
      errors: Invalid
      post: result != null
      on error Invalid: limit != null
    }

    public op runDetail(runId: string) -> RunView {
      route: "GET /v1/runs/:runId"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.run.id != null
      on error NotFound: runId != null
    }

    // The transcript lives in object storage as JSON; the API hands back the
    // bytes it found at the key, not a reshaped copy.
    public op trace(runId: string) -> TraceFile {
      route: "GET /v1/runs/:runId/trace"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: runId != null
    }

    // 200, not 201: cancelling is idempotent. A finished run is a conflict.
    // A queued run is cancelled at once; a running one only gets the flag and
    // the runner stops after the step it is in (Arcod has no cancellable
    // external call, #46).
    public op cancelRun(runId: string) -> Run {
      route: "POST /v1/runs/:runId/cancel"
      status: 200
      effects: store.fetch, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: runId != null
      on error Conflict: runId != null
    }

    // ---- operations ------------------------------------------------------

    // No cron in Arcod (#12): the operator calls sweep with an explicit
    // instant and a runner marks runs that outlived it as failed, so a crash
    // between "running" and the runner does not hide a run forever.
    public op sweep(now: datetime) -> SweepResult {
      route: "POST /v1/sweep"
      effects: store.find, store.update
      errors: none
      post: result.stale >= 0
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count, store.aggregate
      errors: none
      post: result.runs >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: events.dead
      errors: none
      post: result != null
    }

    // ---- consumers -------------------------------------------------------

    // Consumer 1: the loop. Calls the model, runs one allowed tool per turn,
    // stops on a final answer, a denied tool, a tool failure, the step limit
    // or the token budget. Steps are durable, so a redelivery resumes.
    job execute(runId: string) {
      on: events.execute
      retry: 2
      effects: store.fetch, store.find, store.insert, store.update, model.chat, files.put, events.publish, Tools.call, uuid.new
      errors: none
    }

    // Consumer 2: cost. One Usage row per run, written only after the run is
    // finished; the unique rule is the second guard against double billing.
    job invoice(runId: string) {
      on: events.finished
      retry: 2
      effects: store.fetch, store.find, store.insert, files.put, uuid.new
      errors: none
    }
  }
}

environment dev {
  bind store -> postgres(host: "db", port: 5432)
  bind events -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  // localhost is not rewritten for an llm binding: the container cannot reach
  // the host loopback, so the mock address is spelled out.
  bind model -> openai(baseUrl: "http://host.docker.internal:9099/v1", model: "arcod-mock")
  bind uuid -> local
  bind Tools -> endpoint(url: "http://localhost:9098")
  deploy docker
}
