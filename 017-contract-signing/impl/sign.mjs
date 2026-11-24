// Signing is serial: one named person at a time, in the invited order. The
// signature is an scrypt record over the document as it sits in S3 right now,
// the address and the instant, so a later edit of the object breaks verify.
async function sigDigest(value) {
  const bytes = new TextEncoder().encode(String(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function sign(input, io) {
  const id = String(input.id || '');
  const email = String(input.email || '').trim().toLowerCase();
  const code = String(input.code || '').trim();

  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };

  const signers = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  const me = signers.find((s) => s.email === email);
  if (!me || !me.code) return { error: 'Forbidden' };
  if (me.code !== code) return { error: 'Forbidden' };

  if (envelope.status !== 'sent' && envelope.status !== 'in_progress') return { error: 'Conflict' };
  if (me.status !== 'pending') return { error: 'Conflict' };

  const current = signers.find((s) => s.status === 'pending');
  if (!current || current.id !== me.id) return { error: 'Conflict' };

  const document = await io.blobGet(envelope.documentKey);
  if (document == null) return { error: 'Conflict' };
  const text = String(document);

  const signedAt = new Date().toISOString();
  const signature = await sigDigest(text + '|' + email + '|' + signedAt);

  await io.update('Signer', me.id, { status: 'signed', signedAt, signature });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'signed',
    actor: email,
    detail: 'turn ' + me.orderIndex + ' of ' + signers.length,
    at: signedAt,
  });

  const signedCount = signers.filter((s) => s.status === 'signed').length + 1;
  const next = signers.find((s) => s.orderIndex > me.orderIndex && s.status === 'pending');
  const at = new Date().toISOString();

  if (next) {
    await io.update('Envelope', id, { status: 'in_progress', signedCount });
    await io.queuePublish('mail', { envelopeId: id, email: next.email, kind: 'invite' });
  } else {
    // Everyone signed. The manifest is a consumer's job; until it lands the
    // envelope is sealing and the manifest route answers 409.
    await io.update('Envelope', id, { status: 'sealing', signedCount });
    await io.queuePublish('seal', { envelopeId: id });
  }

  const updated = await io.fetch('Envelope', id);
  const rows = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  const audit = (await io.find('Audit', { where: { envelopeId: id }, order: 'at asc', limit: 200 })).items || [];
  return { result: { envelope: updated, signers: rows, audit } };
}
