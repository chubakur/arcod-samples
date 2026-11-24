export async function addSigner(input, io) {
  const id = String(input.id || '');
  const name = String(input.name || '').trim();
  const email = String(input.email || '').trim().toLowerCase();

  if (!name || name.length > 120) return { error: 'Invalid' };
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { error: 'Invalid' };

  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };
  if (envelope.status !== 'draft') return { error: 'Conflict' };

  const existing = await io.find('Signer', { where: { envelopeId: id, email }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const count = await io.count('Signer', { where: { envelopeId: id } });
  const raw = String(await io.new()).replace(/-/g, '');
  const code = raw.slice(0, 10).toUpperCase();
  const signer = {
    id: await io.new(),
    envelopeId: id,
    name,
    email,
    orderIndex: count + 1,
    status: 'pending',
    code,
    invitedAt: null,
    signedAt: null,
    declinedAt: null,
    signature: null,
    reason: null,
  };
  await io.insert('Signer', signer);
  await io.update('Envelope', id, { signerCount: count + 1 });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'signer_added',
    actor: envelope.ownerEmail,
    detail: email + ' is turn ' + (count + 1),
    at: new Date().toISOString(),
  });

  return { result: signer };
}
