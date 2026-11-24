// Test hook only: replace the stored document. The manifest then reports
// verified false, which is what smoke asserts.
export async function tamper(input, io) {
  const id = String(input.id || '');
  const document = String(input.document == null ? '' : input.document);
  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };
  if (document.length < 1) return { error: 'NotFound' };

  await io.blobPut(envelope.documentKey, document, 'text/plain; charset=utf-8');
  await io.update('Envelope', id, { documentSize: document.length });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'tampered',
    actor: 'dev',
    detail: 'document replaced with ' + document.length + ' bytes',
    at: new Date().toISOString(),
  });
  return { result: await io.fetch('Envelope', id) };
}
