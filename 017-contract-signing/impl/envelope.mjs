export async function envelope(input, io) {
  const id = String(input.id || '');
  const row = await io.fetch('Envelope', id);
  if (!row) return { error: 'NotFound' };

  const signers = (await io.find('Signer', { where: { envelopeId: id }, order: 'orderIndex asc' })).items || [];
  const audit = (await io.find('Audit', { where: { envelopeId: id }, order: 'at asc', limit: 200 })).items || [];
  return { result: { envelope: row, signers, audit } };
}
