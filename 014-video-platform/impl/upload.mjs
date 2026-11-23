// Upload puts the bytes in S3 first: a row with a sourceKey that points at
// nothing would make every later step a lie. The heavy work is queued.
export async function upload(input, io) {
  const title = String(input.title || '').trim();
  const owner = String(input.owner || '').trim();
  const checksum = String(input.checksum || '').trim();
  const body = String(input.body == null ? '' : input.body);
  const contentType = String(input.contentType || 'application/octet-stream');
  const durationSec = Number(input.durationSec || 0);

  if (!title || !owner || !checksum || body.length === 0) return { error: 'Invalid' };
  if (!Number.isFinite(durationSec) || durationSec < 0) return { error: 'Invalid' };

  // A checksum is the client's promise about the bytes. The unique rule makes
  // the second upload of the same file a conflict, and this lookup returns the
  // winner instead of pretending a new video was born.
  const found = await io.find('Video', { where: { checksum }, limit: 1 });
  if (found.items && found.items.length > 0) {
    return { error: 'Conflict', fields: { videoId: found.items[0].id } };
  }

  const id = await io.new();
  const sourceKey = 'videos/' + id + '/source';
  await io.blobPut(sourceKey, body, contentType);

  const now = new Date().toISOString();
  const video = {
    id,
    title,
    owner,
    checksum,
    contentType,
    status: 'queued',
    sourceKey,
    sourceBytes: Buffer.byteLength(body, 'utf8'),
    durationSec,
    previewKey: null,
    attempts: 0,
    error: null,
    createdAt: now,
    updatedAt: now
  };
  await io.insert('Video', video);

  await io.queuePublish('transcode', { videoId: id });

  return { result: video };
}
