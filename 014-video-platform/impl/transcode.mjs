// Consumer one: one message per video, the presets run in order inside the
// message. That is deliberate: the generated MySQL adapter keeps one connection
// for the whole service, and two consumers writing at the same time exchange
// result sets (see ISSUES). One message is also the natural unit of progress:
// the video is ready when the last preset lands.
const PROFILES = [
  { preset: '720p', bitrateKbps: 2400, scale: '1280x720' },
  { preset: '480p', bitrateKbps: 900, scale: '854x480' }
];
const MAX_ATTEMPTS = 3;

export async function transcode(input, io) {
  const id = String(input.videoId || '');
  if (!id) return { result: false };

  let found = await io.fetch('Video', id);
  if (!found) return { result: false };
  // A failed video waits for an explicit retry; a ready one needs nothing.
  if (found.status === 'failed' || found.status === 'ready') return { result: true };

  for (const profile of PROFILES) {
    const done = await io.find('Rendition', { where: { videoId: id, preset: profile.preset }, limit: 1 });
    if (done.items && done.items.length > 0) continue;

    const raw = await io.blobGet(found.sourceKey);
    if (raw == null) throw new Error('source object missing for ' + id);
    const bytes = String(raw);
    const now = new Date().toISOString();
    const attempt = Number(found.attempts || 0) + 1;

    // Bad media is not a transient error: it burns the retry budget and parks
    // the video as failed, which is what the owner sees.
    if (bytes.startsWith('CORRUPT')) {
      const failed = attempt >= MAX_ATTEMPTS;
      await io.update('Video', id, {
        attempts: attempt,
        status: failed ? 'failed' : 'transcoding',
        error: 'decoder rejected source',
        updatedAt: now
      });
      throw new Error('decoder rejected source');
    }

    await io.update('Video', id, { attempts: attempt, status: 'transcoding', updatedAt: now });

    // The transcode itself is a stand-in: deterministic derived bytes that a
    // smoke test can compare, not a real H.264 encoder.
    const out = profile.preset + '|' + profile.scale + '|' + profile.bitrateKbps + '|' + Buffer.byteLength(bytes, 'utf8') + '|' + bytes.slice(0, 48);
    const key = 'videos/' + id + '/' + profile.preset;
    await io.blobPut(key, out, 'application/octet-stream');
    await io.insert('Rendition', {
      id: await io.new(),
      videoId: id,
      preset: profile.preset,
      key,
      sizeBytes: Buffer.byteLength(out, 'utf8'),
      bitrateKbps: profile.bitrateKbps,
      createdAt: now
    });
  }

  // The rows the client polls are the source of truth; the update below is the
  // one transition that must not be announced twice.
  const written = await io.find('Rendition', { where: { videoId: id }, limit: 10 });
  const ready = (written.items || []).length;
  if (ready >= 2) {
    const now = new Date().toISOString();
    const previewKey = 'videos/' + id + '/preview';
    const preview = 'thumb ' + id + ' ' + String(found.title || '').slice(0, 16);
    await io.blobPut(previewKey, preview, 'text/plain');
    await io.update('Video', id, { status: 'ready', previewKey, error: null, attempts: 0, updatedAt: now });
    await io.queuePublish('ready', { videoId: id, renditions: ready });
  }

  return { result: true };
}
