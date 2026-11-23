// A consumer that died mid-flight leaves a row in transcoding. The sweep looks
// for stale rows and republishes the same idempotent message; the rendition
// check inside the consumer makes the second delivery harmless.
export async function sweep(input, io) {
  const now = Date.now();
  const stale = await io.find('Video', { where: { status: 'transcoding' }, limit: 100 });
  let queued = 0;
  for (const item of stale.items || []) {
    const touched = Date.parse(item.updatedAt || item.createdAt || '');
    if (Number.isFinite(touched) && now - touched < 60000) continue;
    await io.update('Video', item.id, { status: 'queued', updatedAt: new Date(now).toISOString() });
    await io.queuePublish('transcode', { videoId: item.id });
    queued += 1;
  }
  return { result: { ok: true, queued } };
}
