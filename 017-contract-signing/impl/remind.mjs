// The operator-driven reminder tick: mail the person whose turn it is, but not
// more often than afterSec. Production would call this from a cron workflow.
export async function remind(input, io) {
  const id = String(input.id || '');
  const afterSec = Number(input.afterSec == null ? 3600 : input.afterSec);

  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };
  if (envelope.status !== 'sent' && envelope.status !== 'in_progress') return { error: 'Conflict' };

  const signers = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  const current = signers.find((s) => s.status === 'pending');
  if (!current) return { error: 'Conflict' };

  const last = Date.parse(envelope.lastNotifiedAt || envelope.sentAt || envelope.createdAt);
  const now = Date.now();
  if (Number.isFinite(last) && now - last < afterSec * 1000) return { error: 'Conflict' };

  const at = new Date(now).toISOString();
  await io.update('Envelope', id, { lastNotifiedAt: at, reminders: (envelope.reminders || 0) + 1 });
  await io.insert('Audit', {
    id: await io.new(),
    envelopeId: id,
    kind: 'reminded',
    actor: envelope.ownerEmail,
    detail: 'reminder ' + ((envelope.reminders || 0) + 1) + ' to ' + current.email,
    at,
  });
  await io.queuePublish('mail', { envelopeId: id, email: current.email, kind: 'reminder' });

  return { result: await io.fetch('Envelope', id) };
}
