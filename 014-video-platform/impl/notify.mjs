// Consumer two. The video is ready whatever happens here, so a broken webhook
// costs a retry and a delivery row, not a stuck pipeline.
export async function notify(input, io) {
  const id = String(input.videoId || '');
  if (!id) return { result: false };

  const found = await io.fetch('Video', id);
  if (!found) return { result: false };
  if (found.status !== 'ready') return { result: true };

  // The ready event can be delivered twice; a delivery row is the memory of
  // the first one.
  const done = await io.find('Delivery', { where: { videoId: id }, limit: 1 });
  if (done.items && done.items.length > 0) return { result: true };

  const payload = {
    videoId: id,
    title: found.title,
    previewKey: found.previewKey || '',
    renditions: Number(input.renditions || 0)
  };

  const reply = await io.remote('Hook', 'ready', payload);
  const body = reply && reply.body ? reply.body : reply;
  const ok = (reply && reply.status === 200) || (body && body.received === true);
  await io.insert('Delivery', {
    id: await io.new(),
    videoId: id,
    status: ok ? 'delivered' : 'failed',
    at: new Date().toISOString()
  });
  return { result: true };
}
