export async function createLot(input, io) {
  const title = String(input.title || '').trim();
  const seller = String(input.seller || '').trim();
  const sellerEmail = String(input.sellerEmail || '').trim();
  const startCents = Number(input.startCents);
  const reserveCents = Number(input.reserveCents);
  const durationSec = Number(input.durationSec);
  if (!title || !seller || !sellerEmail) return { error: 'Invalid' };
  if (!Number.isFinite(startCents) || startCents <= 0) return { error: 'Invalid' };
  if (!Number.isFinite(reserveCents) || reserveCents < startCents) return { error: 'Invalid' };
  if (!Number.isFinite(durationSec) || durationSec < 1) return { error: 'Invalid' };

  const now = Math.floor(Date.now() / 1000);
  const lot = {
    id: await io.new(),
    title,
    seller,
    sellerEmail,
    startCents,
    reserveCents,
    endsAt: now + durationSec,
    state: 'open',
    highBidCents: 0,
    highBidder: '',
    extensions: 0,
    closedAt: null
  };
  await io.insert('Lot', lot);
  return { result: lot };
}
