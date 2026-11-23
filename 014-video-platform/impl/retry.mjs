// Retry is a product decision, not a repair tool: only a failed video may be
// requeued, and the attempt counter starts over so the budget is whole again.
export async function retry(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const found = await io.fetch('Video', id);
  if (!found) return { error: 'NotFound' };
  if (found.status !== 'failed') return { error: 'Conflict' };

  const now = new Date().toISOString();
  await io.update('Video', id, { status: 'queued', attempts: 0, error: null, updatedAt: now });
  await io.queuePublish('transcode', { videoId: id });
  return { result: { ok: true, queued: 1 } };
}
