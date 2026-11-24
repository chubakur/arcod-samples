module ci_orchestrator @0.1.0 {
  meta {
    owner: "@genry"
    status: "draft"
    since: "2026-11-24"
  }
}

use capability arcod.std.sql @1
use capability arcod.std.queue @1
use capability arcod.std.blob @1
use capability arcod.std.ids @1

type PipelineId = uuid
type StepId = uuid
type RunId = uuid
type StepRunId = uuid
type ArtifactId = uuid

// What a client submits. The order of the list is the order of execution.
type StepInput = {
  name: string,
  command: string,
  timeoutSec: int = 300
}

type Pipeline = {
  id: PipelineId,
  name: string,
  repo: string,
  branch: string,
  createdAt: int,
  active: boolean
}

// A step is a row, not a JSON blob: the job reads them in position order and
// the API can answer "which pipelines run npm test" without parsing anything.
type StepDef = {
  id: StepId,
  pipelineId: string,
  position: int,
  name: string,
  command: string,
  timeoutSec: int
}

type Run = {
  id: RunId,
  pipelineId: string,
  ref: string,
  status: string,
  attempt: int,
  queuedAt: int,
  startedAt: int?,
  finishedAt: int?,
  cancelRequested: boolean,
  error: string?
}

type StepRun = {
  id: StepRunId,
  runId: string,
  position: int,
  name: string,
  command: string,
  status: string,
  exitCode: int?,
  logKey: string?,
  artifactCount: int,
  startedAt: int?,
  finishedAt: int?
}

type Artifact = {
  id: ArtifactId,
  runId: string,
  stepPosition: int,
  name: string,
  key: string,
  bytes: int,
  sha256: string,
  createdAt: int
}

type RunnerJob = { command: string, timeoutSec: int }
type RunnerArtifact = { name: string, content: string }
type RunnerReply = {
  exitCode: int,
  stdout: string,
  stderr: string,
  durationMs: int,
  artifacts: list<RunnerArtifact>
}

type PipelineView = { pipeline: Pipeline, steps: list<StepDef> }
type StepRunView = {
  position: int,
  name: string,
  command: string,
  status: string,
  exitCode: int?,
  logKey: string?,
  artifactCount: int
}
type RunView = { run: Run, steps: list<StepRunView> }
type LogView = { position: int, name: string, key: string, body: string }
type ArtifactPage = { items: list<Artifact>, total: int }
type ArtifactFile = { name: string, type: string, body: string }
type Stats = {
  queued: int,
  running: int,
  succeeded: int,
  failed: int,
  cancelled: int,
  total: int,
  artifacts: int
}

// The build machine is somebody else's service: the model names the two
// fields it needs, the environment owns the address.
external service Runner : http {
  contract {
    op execute(job: RunnerJob) -> RunnerReply {
      route: "POST /execute"
    }
  }
}

error Invalid
error NotFound
error Conflict

service Orchestrator : http {
  uses store: sql(ttl: 31536000s)
  uses jobs: queue
  uses files: blob
  uses uuid: ids

  effects {
    allow store.insert, store.fetch, store.update, store.find, store.count, jobs.publish, jobs.dead, files.put, files.get, uuid.new, Runner.execute
  }

  contract {
    public op createPipeline(name: string, repo: string, branch: string, steps: list<StepInput>) -> PipelineView {
      route: "POST /v1/pipelines"
      effects: store.find, store.insert, uuid.new
      errors: Invalid, Conflict
      post: result.pipeline.id != null
      on error Invalid: name != null
    }

    public op pipelines() -> list<Pipeline> {
      route: "GET /v1/pipelines"
      effects: store.find
      errors: none
      post: result != null
    }

    public op pipeline(id: PipelineId) -> PipelineView {
      route: "GET /v1/pipelines/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.pipeline.id != null
      on error NotFound: id != null
    }

    // A run is durable before the queue hears about it: the inserted run and
    // its step rows are the idempotency key of the job.
    public op trigger(id: PipelineId, ref: string) -> Run {
      route: "POST /v1/pipelines/:id/runs"
      effects: store.fetch, store.find, store.insert, jobs.publish, uuid.new
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
    }

    public op runs(id: PipelineId) -> list<Run> {
      route: "GET /v1/pipelines/:id/runs"
      effects: store.find
      errors: NotFound
      post: result != null
      on error NotFound: id != null
    }

    public op run(id: RunId) -> RunView {
      route: "GET /v1/runs/:id"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.run.id != null
      on error NotFound: id != null
    }

    // Cooperative cancellation: the flag is durable, the job sees it between
    // steps and stops before the next command starts.
    public op cancel(id: RunId) -> Run {
      route: "POST /v1/runs/:id/cancel"
      effects: store.fetch, store.update
      errors: NotFound, Conflict
      post: result.id != null
      on error NotFound: id != null
      on error Conflict: id != null
    }

    public op log(id: RunId, position: int) -> LogView {
      route: "GET /v1/runs/:id/logs/:position"
      effects: store.fetch, store.find, files.get
      errors: NotFound
      post: result.key != null
      on error NotFound: id != null
    }

    public op artifacts(id: RunId) -> ArtifactPage {
      route: "GET /v1/runs/:id/artifacts"
      effects: store.fetch, store.find
      errors: NotFound
      post: result.total >= 0
      on error NotFound: id != null
    }

    public op artifactFile(id: ArtifactId) -> ArtifactFile {
      route: "GET /v1/artifacts/:id"
      effects: store.fetch, files.get
      errors: NotFound
      post: result.name != null
      on error NotFound: id != null
    }

    public op stats() -> Stats {
      route: "GET /v1/stats"
      effects: store.count
      errors: none
      post: result.total >= 0
    }

    public op dead() -> list<string> {
      route: "GET /v1/dead"
      effects: jobs.dead
      errors: none
      post: result != null
    }

    // One job per run. The body walks the step rows in order, writes each log
    // to object storage and stops at the first non-zero exit.
    job execute(runId: string) {
      on: jobs.execute
      retry: 1
      effects: store.fetch, store.find, store.update, store.count, files.put, Runner.execute
      errors: none
    }
  }
}

environment dev {
  bind store -> mysql(host: "db", port: 3306)
  bind jobs -> redis(host: "queue", port: 6379)
  bind files -> s3(host: "s3", port: 9000)
  bind uuid -> local
  bind Runner -> endpoint(url: "http://runner:9095")
  deploy docker
}
