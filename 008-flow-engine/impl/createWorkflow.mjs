// Definitions are accepted once and never edited: a run pins the step graph it
// started with, so mutating a definition would rewrite history.
const NAME = /^[a-z][a-z0-9-]{1,39}$/;
const STEP = /^[a-z][a-z0-9_]{0,31}$/;
const ACTIONS = new Set(['ok', 'set', 'sleep', 'flaky', 'fail']);

function code(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function int(value, fallback) {
  if (value == null || value === '') return fallback;
  const n = Number(value);
  return Number.isInteger(n) ? n : NaN;
}

function normalize(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const step = {
    name: String(raw.name == null ? '' : raw.name),
    action: String(raw.action == null ? 'ok' : raw.action),
    after: String(raw.after == null ? '' : raw.after),
    key: String(raw.key == null ? '' : raw.key),
    value: String(raw.value == null ? '' : raw.value),
    delayMs: int(raw.delayMs, 0),
    retry: int(raw.retry, 0),
    backoffMs: int(raw.backoffMs, 0),
    failFirst: int(raw.failFirst, 0),
    compensate: String(raw.compensate == null ? '' : raw.compensate),
  };
  if (!STEP.test(step.name)) return null;
  if (!ACTIONS.has(step.action)) return null;
  if (step.after !== '' && !STEP.test(step.after)) return null;
  if (step.after === step.name) return null;
  if (!(step.delayMs >= 0 && step.delayMs <= 3600000)) return null;
  if (!(step.retry >= 0 && step.retry <= 5)) return null;
  if (!(step.backoffMs >= 0 && step.backoffMs <= 60000)) return null;
  if (!(step.failFirst >= 0 && step.failFirst <= 10)) return null;
  if (step.action === 'set' && step.key === '') return null;
  return step;
}

// Kahn's algorithm: a definition with a cycle would leave runs parked forever.
function acyclic(steps) {
  const left = new Map(steps.map((s) => [s.name, s.after ? 1 : 0]));
  const byAfter = new Map();
  for (const s of steps) {
    if (!s.after) continue;
    if (!left.has(s.after)) return null;
    const list = byAfter.get(s.after) || [];
    list.push(s.name);
    byAfter.set(s.after, list);
  }
  const queue = steps.filter((s) => !s.after).map((s) => s.name);
  let seen = 0;
  while (queue.length) {
    const name = queue.shift();
    seen += 1;
    for (const next of byAfter.get(name) || []) {
      left.set(next, left.get(next) - 1);
      if (left.get(next) === 0) queue.push(next);
    }
  }
  return seen === steps.length ? steps : null;
}

export async function createWorkflow(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  if (!NAME.test(name)) return { error: 'Invalid' };

  const raw = Array.isArray(input.steps) ? input.steps : [];
  if (raw.length < 1 || raw.length > 40) return { error: 'Invalid' };

  const steps = [];
  const seen = new Set();
  for (const item of raw) {
    const step = normalize(item);
    if (!step || seen.has(step.name)) return { error: 'Invalid' };
    seen.add(step.name);
    steps.push(step);
  }
  if (!acyclic(steps)) return { error: 'Invalid' };

  const existing = await io.fetch('WorkflowRec', name);
  if (existing) return { error: 'Conflict' };

  const createdAt = new Date().toISOString();
  const row = {
    id: name,
    name,
    version: 1,
    steps: JSON.stringify(steps),
    createdAt,
  };

  try {
    await io.insert('WorkflowRec', row);
  } catch (err) {
    if (code(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  return { result: { name, version: 1, steps, createdAt } };
}
