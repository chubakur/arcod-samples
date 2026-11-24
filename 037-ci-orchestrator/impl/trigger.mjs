// The run and its step rows hit the database before the queue does. A
// redelivered job then finds the same rows and cannot double-run a step.
const ACTIVE = ['queued', 'running', 'cancelling'];

export async function trigger(input, io) {
  const id = String(input.id || '');
  const ref = String(input.ref || '').trim().slice(0, 200) || 'main';

  const pipeline = await io.fetch('Pipeline', id);
  if (!pipeline) return { error: 'NotFound' };
  if (!pipeline.active) return { error: 'Conflict' };

  const recent = await io.find('Run', { where: { pipelineId: id }, order: 'queuedAt desc', limit: 20 });
  for (const row of (recent.items || [])) {
    if (ACTIVE.indexOf(String(row.status)) >= 0) return { error: 'Conflict' };
  }

  const defs = await io.find('StepDef', { where: { pipelineId: id }, order: 'position asc', limit: 50 });
  const steps = defs.items || [];
  if (steps.length === 0) return { error: 'Conflict' };

  const run = {
    id: await io.new(),
    pipelineId: id,
    ref,
    status: 'queued',
    attempt: 0,
    queuedAt: Date.now(),
    startedAt: null,
    finishedAt: null,
    cancelRequested: false,
    error: null,
  };
  await io.insert('Run', run);

  for (const step of steps) {
    await io.insert('StepRun', {
      id: await io.new(),
      runId: run.id,
      position: step.position,
      name: step.name,
      command: step.command,
      status: 'pending',
      exitCode: null,
      logKey: null,
      artifactCount: 0,
      startedAt: null,
      finishedAt: null,
    });
  }

  await io.queuePublish('execute', { runId: run.id });
  return { result: run };
}
