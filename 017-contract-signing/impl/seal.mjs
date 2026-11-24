// Seal consumer: the manifest is built from the signer rows, hashed with the
// runtime's salted hash, stored next to the document and only then does the
// envelope become completed.
async function sealDigest(value) {
  const bytes = new TextEncoder().encode(String(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function seal(input, io) {
  const envelopeId = String(input.envelopeId || '');
  const envelope = await io.fetch('Envelope', envelopeId);
  if (!envelope) return { result: false };
  if (envelope.status !== 'sealing') return { result: false };

  const signers = (await io.find('Signer', { where: { envelopeId }, order: 'orderIndex asc' })).items || [];
  const sealedAt = new Date().toISOString();
  const manifest = {
    envelopeId,
    title: envelope.title,
    documentSize: envelope.documentSize,
    sealedAt,
    signers: signers.map((s) => ({
      name: s.name,
      email: s.email,
      orderIndex: s.orderIndex,
      signedAt: s.signedAt || null,
      signature: s.signature || null,
    })),
  };

  const body = JSON.stringify(manifest);
  const manifestHash = await sealDigest(body);
  await io.blobPut(envelopeId + '/manifest.json', body, 'application/json');
  await io.update('Envelope', envelopeId, {
    status: 'completed',
    closedAt: sealedAt,
    manifestHash,
  });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId,
    kind: 'sealed',
    actor: 'sealer',
    detail: signers.length + ' signature(s) sealed',
    at: sealedAt,
  });

  return { result: true };
}
