function listStepView(state) {
  return {
    name: state.name,
    kind: state.kind,
    status: state.status,
    attempts: Number(state.attempts || 0),
    dueAt: state.dueAt == null ? null : state.dueAt,
    output: state.output == null ? '' : String(state.output),
    error: state.error == null ? '' : String(state.error),
  };
}

function runView(run, states) {
  return {
    id: run.id,
    workflow: run.workflow,
    version: Number(run.version || 1),
    status: run.status,
    input: run.input == null ? '' : String(run.input),
    vars: typeof run.vars === 'string' && run.vars !== '' ? run.vars : '{}',
    step: run.step == null ? '' : String(run.step),
    attempts: Number(run.attempts || 0),
    nextAt: run.nextAt == null ? null : run.nextAt,
    error: run.error == null ? '' : String(run.error),
    steps: states.map(listStepView),
    createdAt: run.createdAt,
    updatedAt: run.updatedAt,
  };
}

const KNOWN = new Set(['', 'pending', 'running', 'compensating', 'done', 'failed', 'cancelled']);

export async function listRuns(input, io) {
  const status = String(input.status == null ? '' : input.status).trim();
  const limit = Number(input.limit == null ? 20 : input.limit);
  if (!KNOWN.has(status)) return { error: 'Invalid' };
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) return { error: 'Invalid' };

  const query = { order: 'createdAt desc', limit: limit + 1 };
  if (status) query.where = { status };
  if (input.cursor) query.cursor = String(input.cursor);

  const page = await io.find('RunRec', query);
  const rows = (page.items || []).slice();
  const next = rows.length > limit ? (page.next || null) : null;
  if (rows.length > limit) rows.length = limit;

  const items = [];
  for (const run of rows) {
    const states = await io.find('StepState', { where: { runId: run.id }, limit: 200 });
    const sorted = (states.items || []).slice().sort((a, b) => Number(a.order || 0) - Number(b.order || 0));
    items.push(runView(run, sorted));
  }

  return { result: { items, next } };
}
