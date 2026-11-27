// Replay is queued, not synchronous: a long log must not hold the HTTP socket.
export async function replay(input, io) {
  const streamId = String(input.streamId || '');
  const head = await io.fetch('Stream', streamId);
  if (!head) return { error: 'NotFound' };
  await io.queuePublish('rebuild', streamId);
  return { result: { queued: true, topic: 'rebuild', subject: streamId } };
}
