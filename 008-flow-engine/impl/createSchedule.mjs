const SCHED_NAME = /^[a-z][a-z0-9-]{1,39}$/;

function schedCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

export async function createSchedule(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const workflow = String(input.workflow == null ? '' : input.workflow).trim();
  const everySeconds = Number(input.everySeconds == null ? 60 : input.everySeconds);

  if (!SCHED_NAME.test(name)) return { error: 'Invalid' };
  if (!Number.isInteger(everySeconds) || everySeconds < 1 || everySeconds > 86400) return { error: 'Invalid' };

  const def = await io.fetch('WorkflowRec', workflow);
  if (!def) return { error: 'NotFound' };

  const nextAt = new Date(Date.now() + everySeconds * 1000).toISOString();
  const row = { id: name, name, workflow, everySeconds, nextAt, enabled: true };

  try {
    await io.insert('ScheduleRec', row);
  } catch (err) {
    if (schedCode(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  return { result: { name, workflow, everySeconds, nextAt, enabled: true } };
}
