export async function stats(input, io) {
  const envelopes = await io.count('Envelope', {});
  const completed = await io.count('Envelope', { where: { status: 'completed' } });
  const declined = await io.count('Envelope', { where: { status: 'declined' } });
  const pendingSigners = await io.count('Signer', { where: { status: 'pending' } });
  const notifications = await io.count('Notification', {});
  return { result: { envelopes, completed, declined, pendingSigners, notifications } };
}
