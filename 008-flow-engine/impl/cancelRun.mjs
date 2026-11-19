// Cancel is a rollback, not a flag: completed steps are compensated in
// reverse order and only then does the run report cancelled. Steps that never
// ran are left untouched.
export async function cancelRun(input, io) {
  const id = String(input.id == null ? '' : input.id).trim();
  const run = id ? await io.fetch('RunRec', id) : null;
  if (!run) return { error: 'NotFound' };
  if (run.status === 'done' || run.status === 'failed' || run.status === 'cancelled') {
    return { error: 'Conflict' };
  }

  const def = await io.fetch('WorkflowRec', run.workflow);
  let steps = [];
  try {
    steps = def ? JSON.parse(def.steps || '[]') : [];
  } catch (err) {
    steps = [];
  }

  const page = await io.find('StepState', { where: { runId: id }, limit: 200 });
  const states = new Map();
  for (const item of page.items || []) {
    if (item.kind === 'step') states.set(item.name, item);
  }

  for (let i = steps.length - 1; i >= 0; i -= 1) {
    const step = steps[i];
    const state = states.get(step.name);
    if (!state || state.status !== 'done') continue;

    const name = '~' + step.name;
    const action = String(step.compensate || '');
    const row = {
      id: id + ':' + name,
      runId: id,
      name,
      kind: 'compensate',
      status: action ? 'done' : 'skipped',
      attempts: action ? 1 : 0,
      dueAt: null,
      output: action || '',
      error: '',
      order: 1000 + i,
    };
    const existing = await io.fetch('StepState', row.id);
    if (existing) await io.update('StepState', row.id, row);
    else await io.insert('StepState', row);
  }

  await io.update('RunRec', id, {
    status: 'cancelled',
    error: '',
    nextAt: null,
    step: '',
    generation: Number(run.generation || 0) + 1,
    updatedAt: new Date().toISOString(),
  });

  const fresh = await io.fetch('RunRec', id);
  const again = await io.find('StepState', { where: { runId: id }, limit: 200 });
  const list = (again.items || []).slice().sort((a, b) => Number(a.order || 0) - Number(b.order || 0));

  return {
    result: {
      id: fresh.id,
      workflow: fresh.workflow,
      version: Number(fresh.version || 1),
      status: fresh.status,
      input: fresh.input == null ? '' : String(fresh.input),
      vars: typeof fresh.vars === 'string' && fresh.vars !== '' ? fresh.vars : '{}',
      step: fresh.step == null ? '' : String(fresh.step),
      attempts: Number(fresh.attempts || 0),
      nextAt: fresh.nextAt == null ? null : fresh.nextAt,
      error: fresh.error == null ? '' : String(fresh.error),
      steps: list.map((s) => ({
        name: s.name,
        kind: s.kind,
        status: s.status,
        attempts: Number(s.attempts || 0),
        dueAt: s.dueAt == null ? null : s.dueAt,
        output: s.output == null ? '' : String(s.output),
        error: s.error == null ? '' : String(s.error),
      })),
      createdAt: fresh.createdAt,
      updatedAt: fresh.updatedAt,
    },
  };
}
