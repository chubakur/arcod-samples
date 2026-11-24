// The pipeline and its steps are written in one call. A step list is the
// contract, not free text: name, command and a timeout the runner will honour.
const MAX_STEPS = 12;

function clean(value, max) {
  return String(value == null ? '' : value).trim().slice(0, max);
}

export async function createPipeline(input, io) {
  const name = clean(input.name, 80);
  const repo = clean(input.repo, 200);
  const branch = clean(input.branch, 100) || 'main';
  const steps = Array.isArray(input.steps) ? input.steps.slice(0, MAX_STEPS) : [];

  if (name.length < 2 || !repo) return { error: 'Invalid' };
  if (steps.length === 0) return { error: 'Invalid' };

  const normalized = [];
  const seen = new Set();
  for (let i = 0; i < steps.length; i += 1) {
    const raw = steps[i] || {};
    const stepName = clean(raw.name, 60);
    const command = clean(raw.command, 500);
    const timeoutSec = Math.max(1, Math.min(3600, Number(raw.timeoutSec || 300)));
    if (!stepName || !command || seen.has(stepName)) return { error: 'Invalid' };
    seen.add(stepName);
    normalized.push({ name: stepName, command, timeoutSec });
  }

  // A name is the human key: the smoke test depends on 409 being an answer,
  // not on two pipelines quietly sharing one dashboard row.
  const existing = await io.find('Pipeline', { where: { name }, limit: 1 });
  if (((existing && existing.items) || []).length > 0) return { error: 'Conflict' };

  const pipeline = {
    id: await io.new(),
    name,
    repo,
    branch,
    createdAt: Date.now(),
    active: true,
  };
  await io.insert('Pipeline', pipeline);

  const rows = [];
  for (let i = 0; i < normalized.length; i += 1) {
    const step = {
      id: await io.new(),
      pipelineId: pipeline.id,
      position: i + 1,
      name: normalized[i].name,
      command: normalized[i].command,
      timeoutSec: normalized[i].timeoutSec,
    };
    await io.insert('StepDef', step);
    rows.push(step);
  }

  return { result: { pipeline, steps: rows } };
}
