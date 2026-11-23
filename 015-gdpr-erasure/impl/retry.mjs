// Retry is a republish, not a reset: the consumer is idempotent per dataset,
// so a second pass only finishes what the first one left behind.
export async function retry(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const record = await io.fetch('ErasureRequest', id);
  if (!record) return { error: 'NotFound' };
  if (record.state === 'erasing') return { error: 'Conflict' };

  const now = new Date().toISOString();
  if (record.state === 'certified') return { result: { ok: true, queued: 0 } };
  if (record.state === 'erased') {
    await io.queuePublish('erased', { requestId: id });
    return { result: { ok: true, queued: 1 } };
  }

  if (record.state === 'failed') {
    await io.update('ErasureRequest', id, { state: 'pending', updatedAt: now });
  }
  await io.queuePublish('erase', { requestId: id });
  return { result: { ok: true, queued: 1 } };
}
