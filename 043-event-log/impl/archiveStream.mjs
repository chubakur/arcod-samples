export async function archiveStream(input, io) {
  const streamId = String(input.streamId || '');
  const head = await io.fetch('Stream', streamId);
  if (!head) return { error: 'NotFound' };
  await io.queuePublish('archive', streamId);
  return { result: { queued: true, topic: 'archive', subject: streamId } };
}
