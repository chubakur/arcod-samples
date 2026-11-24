// Mail consumer. One message is { envelopeId, email, kind }; the body renders
// the copy and records the receipt row so smoke can count what left the system.
export async function deliver(input, io) {
  const envelopeId = String(input.envelopeId || '');
  const email = String(input.email || '').trim().toLowerCase();
  const kind = String(input.kind || 'invite');

  const envelope = await io.fetch('Envelope', envelopeId);
  if (!envelope) return { result: false };

  const found = await io.find('Signer', { where: { envelopeId, email }, limit: 1 });
  const signer = (found.items || [])[0] || null;

  let subject = '';
  let text = '';
  if (kind === 'invite' || kind === 'reminder') {
    if (!signer) return { result: false };
    subject = (kind === 'invite' ? 'Signature requested: ' : 'Reminder: ') + envelope.title;
    text = 'Hello ' + signer.name + ',\n\n' +
      (kind === 'invite' ? 'You are invited to sign' : 'A reminder to sign') +
      ' "' + envelope.title + '" (turn ' + signer.orderIndex + ' of ' + envelope.signerCount + ').\n' +
      'Your code: ' + signer.code + '\n\nDocument: ' + envelope.documentSize + ' bytes.';
  } else if (kind === 'declined') {
    subject = 'Envelope declined: ' + envelope.title;
    text = 'A signer declined "' + envelope.title + '". The envelope is closed.';
  } else {
    return { result: false };
  }

  const reply = await io.remote('Mailer', 'send', {
    from: 'contracts@arcod.test',
    to: email,
    subject,
    text,
  });

  await io.insert('Notification', {
    id: await io.new(),
    envelopeId,
    signerId: signer ? signer.id : '',
    kind,
    to: email,
    subject,
    at: new Date().toISOString(),
  });

  if (signer && kind === 'invite' && !signer.invitedAt) {
    await io.update('Signer', signer.id, { invitedAt: new Date().toISOString() });
  }
  if (kind === 'invite' || kind === 'reminder') {
    await io.update('Envelope', envelopeId, { lastNotifiedAt: new Date().toISOString() });
  }

  return { result: { id: reply && reply.id ? reply.id : '' } };
}
