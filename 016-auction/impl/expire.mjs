// Dev helper: move the end into the past so the closing tick has work now.
// It is the only body that writes endsAt without the anti-sniping rule.
export async function expire(input, io) {
  const lotId = String(input.lotId || '');
  const row = await io.fetch('Lot', lotId);
  if (!row) return { error: 'NotFound' };
  const now = Math.floor(Date.now() / 1000);
  await io.update('Lot', lotId, { endsAt: now - 1 });
  const updated = await io.fetch('Lot', lotId);
  return { result: updated };
}
