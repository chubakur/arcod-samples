// A run is seeded with one StepState per definition step. Seeding at creation
// (not on the first tick) means the run view is complete from the first read,
// and a tick only ever updates states it can see.
export async function createRun(input, io) {
  const workflow = String(input.workflow == null ? '' : input.workflow).trim();
  const text = String(input.input == null ? '' : input.input);
  if (!workflow) return { error: 'Invalid' };
  if (text.length > 4000) return { error: 'Invalid' };

  const def = await io.fetch('WorkflowRec', workflow);
  if (!def) return { error: 'NotFound' };

  let steps = [];
  try {
    steps = JSON.parse(def.steps || '[]');
  } catch (err) {
    steps = [];
  }

  const id = await io.new();
  const createdAt = new Date().toISOString();

  const states = [];
  for (let i = 0; i < steps.length; i += 1) {
    const step = steps[i];
    const state = {
      id: id + ':' + step.name,
      runId: id,
      name: step.name,
      kind: 'step',
      status: 'pending',
      attempts: 0,
      dueAt: null,
      output: '',
      error: '',
      order: i,
    };
    await io.insert('StepState', state);
    states.push(state);
  }

  const run = {
    id,
    workflow,
    version: Number(def.version || 1),
    status: 'pending',
    input: text,
    vars: '{}',
    step: '',
    attempts: 0,
    nextAt: createdAt,
    error: '',
    generation: 0,
    createdAt,
    updatedAt: createdAt,
  };
  await io.insert('RunRec', run);

  return {
    result: {
      id,
      workflow,
      version: run.version,
      status: run.status,
      input: text,
      vars: '{}',
      step: '',
      attempts: 0,
      nextAt: createdAt,
      error: '',
      steps: states.map((s) => ({
        name: s.name,
        kind: s.kind,
        status: s.status,
        attempts: 0,
        dueAt: null,
        output: '',
        error: '',
      })),
      createdAt,
      updatedAt: createdAt,
    },
  };
}
