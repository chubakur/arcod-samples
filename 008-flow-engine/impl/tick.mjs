// One tick = one wave of progress. The service has no timer facility of its
// own, so "due" is a timestamp on the run and the caller decides when to ask.
// A claim row (unique per run+generation) is the lease: the insert either wins
// or throws Conflict, and only the winner touches step states.

function tickCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function render(tpl, run, vars) {
  return String(tpl == null ? '' : tpl)
    .replace(/\{\{\s*input\s*\}\}/g, String(run.input || ''))
    .replace(/\{\{\s*vars\.([a-zA-Z0-9_]+)\s*\}\}/g, (_, key) => {
      const value = vars[key];
      return value == null ? '' : String(value);
    });
}

function parseSteps(def) {
  try {
    const steps = JSON.parse(def.steps || '[]');
    return Array.isArray(steps) ? steps : [];
  } catch (err) {
    return [];
  }
}

async function loadStates(io, runId) {
  const page = await io.find('StepState', { where: { runId }, limit: 200 });
  const map = new Map();
  for (const item of page.items || []) {
    if (item.kind === 'step') map.set(item.name, item);
  }
  return map;
}

async function runAction(action, step, attempt, run, vars) {
  const kind = String(step.action || 'ok');
  if (kind === 'fail') {
    return { ok: false, error: String(step.value || ('step ' + step.name + ' failed')) };
  }
  if (kind === 'flaky') {
    if (attempt <= Number(step.failFirst || 0)) {
      return { ok: false, error: 'flaky failure on attempt ' + attempt };
    }
    return { ok: true, output: render(step.value, run, vars) };
  }
  if (kind === 'set') {
    vars[String(step.key)] = render(step.value, run, vars);
    return { ok: true, output: render(step.value, run, vars) };
  }
  return { ok: true, output: render(step.value, run, vars) };
}

// Roll back every completed step, newest first. Compensations are best
// effort: a failing rollback is recorded but never blocks the rest.
async function compensate(io, run, steps, states, kind, reason, advanced) {
  const nowMs = Date.now();
  for (let i = steps.length - 1; i >= 0; i -= 1) {
    const step = steps[i];
    const state = states.get(step.name);
    if (!state || state.status !== 'done') continue;

    const name = '~' + step.name;
    const action = String(step.compensate || '');
    const existing = await io.fetch('StepState', run.id + ':' + name);
    const row = {
      id: run.id + ':' + name,
      runId: run.id,
      name,
      kind: 'compensate',
      status: action ? 'done' : 'skipped',
      attempts: action ? 1 : 0,
      dueAt: null,
      output: action ? render(step.value, run, {}) : '',
      error: '',
      order: 1000 + i,
    };
    if (existing) await io.update('StepState', row.id, row);
    else await io.insert('StepState', row);
  }

  const patch = {
    status: kind === 'cancel' ? 'cancelled' : 'failed',
    error: kind === 'cancel' ? '' : String(reason || 'run failed'),
    nextAt: null,
    step: '',
    generation: Number(run.generation || 0) + 1,
    updatedAt: iso(nowMs),
  };
  const updated = await io.update('RunRec', run.id, patch);
  return { advanced: advanced || 0, state: patch.status, run: updated || { ...run, ...patch } };
}

async function advance(io, run, def) {
  const steps = parseSteps(def);
  const states = await loadStates(io, run.id);
  let vars = {};
  try {
    vars = run.vars ? JSON.parse(run.vars) : {};
  } catch (err) {
    vars = {};
  }

  let advanced = 0;
  let touched = '';
  const nowIso = iso(Date.now());

  for (let round = 0; round < steps.length + 2; round += 1) {
    let moved = false;

    for (let i = 0; i < steps.length; i += 1) {
      const step = steps[i];
      const state = states.get(step.name);
      if (!state) continue;
      if (state.status === 'done' || state.status === 'skipped' || state.status === 'failed') continue;

      if (step.after) {
        const dep = states.get(step.after);
        if (!dep || dep.status !== 'done') continue;
      }

      if (state.status === 'pending') {
        const delay = Number(step.delayMs || 0);
        if (delay > 0) {
          state.status = 'waiting';
          state.dueAt = iso(Date.now() + delay);
          await io.update('StepState', state.id, { status: state.status, dueAt: state.dueAt });
          advanced += 1;
          touched = step.name;
          moved = true;
          continue;
        }
      }

      if (state.status === 'waiting') {
        if (state.dueAt && String(state.dueAt) > nowIso) continue;
      }

      const attempt = Number(state.attempts || 0) + 1;
      const outcome = await runAction(step.action, step, attempt, run, vars);

      if (outcome.ok) {
        state.status = 'done';
        state.attempts = attempt;
        state.output = outcome.output || '';
        state.error = '';
        await io.update('StepState', state.id, {
          status: 'done',
          attempts: attempt,
          output: state.output,
          error: '',
          dueAt: null,
        });
      } else {
        const retry = Number(step.retry || 0);
        state.attempts = attempt;
        state.error = outcome.error;
        if (attempt <= retry) {
          const backoff = Number(step.backoffMs || 0) * Math.pow(2, attempt - 1);
          state.status = 'waiting';
          state.dueAt = iso(Date.now() + backoff);
          await io.update('StepState', state.id, {
            status: 'waiting',
            attempts: attempt,
            error: state.error,
            dueAt: state.dueAt,
          });
        } else {
          state.status = 'failed';
          await io.update('StepState', state.id, {
            status: 'failed',
            attempts: attempt,
            error: state.error,
            dueAt: null,
          });
        }
      }
      advanced += 1;
      touched = step.name;
      moved = true;
    }

    if (!moved) break;
  }

  const all = steps.map((s) => states.get(s.name));
  const failed = all.find((s) => s && s.status === 'failed');
  if (failed) {
    return compensate(io, run, steps, states, 'fail', failed.error || 'step failed', advanced);
  }

  const doneCount = all.filter((s) => s && s.status === 'done').length;
  if (doneCount === steps.length && steps.length > 0) {
    const patch = {
      status: 'done',
      step: touched || '',
      attempts: all.reduce((sum, s) => sum + Number((s && s.attempts) || 0), 0),
      vars: JSON.stringify(vars),
      nextAt: null,
      error: '',
      generation: Number(run.generation || 0) + 1,
      updatedAt: iso(Date.now()),
    };
    const updated = await io.update('RunRec', run.id, patch);
    return { advanced, state: 'done', run: updated || { ...run, ...patch } };
  }

  const waiting = all.filter((s) => s && s.status === 'waiting' && s.dueAt).map((s) => String(s.dueAt));
  waiting.sort();
  const nextAt = waiting.length ? waiting[0] : iso(Date.now() + 1000);

  const patch = {
    status: 'running',
    step: touched || run.step || '',
    attempts: all.reduce((sum, s) => sum + Number((s && s.attempts) || 0), 0),
    vars: JSON.stringify(vars),
    nextAt,
    error: '',
    generation: Number(run.generation || 0) + 1,
    updatedAt: iso(Date.now()),
  };
  const updated = await io.update('RunRec', run.id, patch);
  return { advanced, state: 'running', run: updated || { ...run, ...patch } };
}

export async function tick(input, io) {
  const limit = Number(input.limit == null ? 20 : input.limit);
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return { error: 'Invalid' };

  const nowIso = iso(Date.now());
  let spawned = 0;

  const schedules = await io.find('ScheduleRec', { limit: 200 });
  for (const schedule of schedules.items || []) {
    if (!schedule.enabled) continue;
    if (String(schedule.nextAt) > nowIso) continue;
    if (spawned >= limit) break;

    const def = await io.fetch('WorkflowRec', schedule.workflow);
    if (!def) continue;
    const steps = parseSteps(def);
    const id = await io.new();
    const createdAt = iso(Date.now());

    for (let i = 0; i < steps.length; i += 1) {
      await io.insert('StepState', {
        id: id + ':' + steps[i].name,
        runId: id,
        name: steps[i].name,
        kind: 'step',
        status: 'pending',
        attempts: 0,
        dueAt: null,
        output: '',
        error: '',
        order: i,
      });
    }

    await io.insert('RunRec', {
      id,
      workflow: schedule.workflow,
      version: Number(def.version || 1),
      status: 'pending',
      input: '',
      vars: '{}',
      step: '',
      attempts: 0,
      nextAt: createdAt,
      error: '',
      generation: 0,
      createdAt,
      updatedAt: createdAt,
    });

    let next = new Date(String(schedule.nextAt)).getTime();
    const every = Number(schedule.everySeconds || 60) * 1000;
    const nowMs = Date.now();
    do {
      next += every;
    } while (next <= nowMs);
    await io.update('ScheduleRec', schedule.name, { nextAt: iso(next) });
    spawned += 1;
  }

  const pending = await io.find('RunRec', { where: { status: 'pending' }, limit: 200 });
  const running = await io.find('RunRec', { where: { status: 'running' }, limit: 200 });
  const due = [...(pending.items || []), ...(running.items || [])]
    .filter((run) => run.nextAt == null || String(run.nextAt) <= nowIso)
    .sort((a, b) => String(a.nextAt || '').localeCompare(String(b.nextAt || '')))
    .slice(0, limit);

  let claimed = 0;
  let advanced = 0;
  let completed = 0;
  let failed = 0;
  const items = [];

  for (const candidate of due) {
    const slot = candidate.id + ':' + Number(candidate.generation || 0);
    try {
      await io.insert('Claim', {
        id: slot,
        slot,
        runId: candidate.id,
        generation: Number(candidate.generation || 0),
        at: nowIso,
      });
    } catch (err) {
      if (tickCode(err) === 'Conflict') continue;
      throw err;
    }
    claimed += 1;

    const run = await io.fetch('RunRec', candidate.id);
    if (!run) continue;
    if (run.status !== 'pending' && run.status !== 'running') continue;

    const def = await io.fetch('WorkflowRec', run.workflow);
    if (!def) {
      await io.update('RunRec', run.id, {
        status: 'failed',
        error: 'definition ' + run.workflow + ' is gone',
        nextAt: null,
        updatedAt: iso(Date.now()),
      });
      failed += 1;
      items.push({ run: run.id, workflow: run.workflow, advanced: 0, state: 'failed' });
      continue;
    }

    const out = await advance(io, run, def);
    advanced += out.advanced;
    if (out.state === 'done') completed += 1;
    if (out.state === 'failed') failed += 1;
    items.push({ run: run.id, workflow: run.workflow, advanced: out.advanced, state: out.state });
  }

  return {
    result: {
      now: nowIso,
      claimed,
      advanced,
      completed,
      failed,
      spawned,
      items,
    },
  };
}
