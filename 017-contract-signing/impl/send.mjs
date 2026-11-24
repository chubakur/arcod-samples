export async function send(input, io) {
  const id = String(input.id || '');
  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };
  if (envelope.status !== 'draft') return { error: 'Conflict' };

  const signers = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  if (signers.length === 0) return { error: 'Conflict' };

  const at = new Date().toISOString();
  await io.update('Envelope', id, { status: 'sent', sentAt: at, lastNotifiedAt: at });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'sent',
    actor: envelope.ownerEmail,
    detail: signers.length + ' signer(s), turn 1 is ' + signers[0].email,
    at,
  });
  await io.queuePublish('mail', { envelopeId: id, email: signers[0].email, kind: 'invite' });

  return { result: await io.fetch('Envelope', id) };
}
