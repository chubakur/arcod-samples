// The document goes to the blob store first: a row without an object would be
// a dangling pointer, and S3 is the only place the bytes live.
export async function create(input, io) {
  const title = String(input.title || '').trim();
  const ownerEmail = String(input.ownerEmail || '').trim().toLowerCase();
  const document = String(input.document == null ? '' : input.document);

  if (!title || title.length > 160) return { error: 'Invalid' };
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(ownerEmail)) return { error: 'Invalid' };
  if (document.length < 1 || document.length > 524288) return { error: 'Invalid' };

  const id = await io.new();
  const documentKey = id + '/document.txt';
  await io.blobPut(documentKey, document, 'text/plain; charset=utf-8');

  const envelope = {
    id,
    title,
    ownerEmail,
    documentKey,
    documentSize: document.length,
    status: 'draft',
    signerCount: 0,
    signedCount: 0,
    createdAt: new Date().toISOString(),
    sentAt: null,
    closedAt: null,
    lastNotifiedAt: null,
    reminders: 0,
    manifestHash: null,
  };
  await io.insert('Envelope', envelope);
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'created',
    actor: ownerEmail,
    detail: 'document stored (' + document.length + ' bytes)',
    at: envelope.createdAt,
  });

  return { result: envelope };
}
