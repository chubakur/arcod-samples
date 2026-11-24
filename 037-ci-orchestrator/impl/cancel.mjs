const CANCEL_TERMINAL = ['succeeded', 'failed', 'cancelled'];

export async function cancel(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Run', id);
  if (!found) return { error: 'NotFound' };
  if (CANCEL_TERMINAL.indexOf(String(found.status)) >= 0) return { error: 'Conflict' };
  if (found.cancelRequested) return { result: found };

  await io.update('Run', id, { cancelRequested: true, status: 'cancelling' });
  const fresh = await io.fetch('Run', id);
  return { result: fresh };
}
