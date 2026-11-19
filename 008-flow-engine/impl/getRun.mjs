function getRunStepView(state) {
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

export async function getRun(input, io) {
  const id = String(input.id == null ? '' : input.id).trim();
  if (!id) return { error: 'NotFound' };

  const run = await io.fetch('RunRec', id);
  if (!run) return { error: 'NotFound' };

  const page = await io.find('StepState', { where: { runId: id }, limit: 200 });
  const states = (page.items || []).slice();
  states.sort((a, b) => Number(a.order || 0) - Number(b.order || 0));

  let vars = run.vars;
  if (vars == null || vars === '') vars = '{}';
  if (typeof vars !== 'string') vars = JSON.stringify(vars);

  return {
    result: {
      id: run.id,
      workflow: run.workflow,
      version: Number(run.version || 1),
      status: run.status,
      input: run.input == null ? '' : String(run.input),
      vars,
      step: run.step == null ? '' : String(run.step),
      attempts: Number(run.attempts || 0),
      nextAt: run.nextAt == null ? null : run.nextAt,
      error: run.error == null ? '' : String(run.error),
      steps: states.map(getRunStepView),
      createdAt: run.createdAt,
      updatedAt: run.updatedAt,
    },
  };
}
