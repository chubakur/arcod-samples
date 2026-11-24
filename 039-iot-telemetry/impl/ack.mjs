export async function ack(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const alert = await io['fetch']('Alert', id);
  if (!alert) return { error: 'NotFound' };
  if (alert.status === 'resolved') return { error: 'Conflict' };

  const patch = { status: 'acked', ackedAt: new Date().toISOString() };
  const updated = await io.update('Alert', id, patch);
  return { result: updated || { ...alert, ...patch } };
}
