export async function decline(input, io) {
  const id = String(input.id || '');
  const email = String(input.email || '').trim().toLowerCase();
  const code = String(input.code || '').trim();
  const reason = String(input.reason || '').trim();

  if (!reason) return { error: 'Invalid' };
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

  const at = new Date().toISOString();
  await io.update('Signer', me.id, { status: 'declined', declinedAt: at, reason });
  // Everyone behind the refuser is out of the route: they never get a turn.
  for (const later of signers) {
    if (later.orderIndex > me.orderIndex && later.status === 'pending') {
      await io.update('Signer', later.id, { status: 'skipped' });
    }
  }
  await io.update('Envelope', id, { status: 'declined', closedAt: at });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'declined',
    actor: email,
    detail: reason.slice(0, 200),
    at,
  });
  await io.queuePublish('mail', { envelopeId: id, email: envelope.ownerEmail, kind: 'declined' });

  const updated = await io.fetch('Envelope', id);
  const rows = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  const audit = (await io.find('Audit', { where: { envelopeId: id }, order: 'at asc', limit: 200 })).items || [];
  return { result: { envelope: updated, signers: rows, audit } };
}
