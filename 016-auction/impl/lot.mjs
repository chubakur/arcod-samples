export async function lot(input, io) {
  const lotId = String(input.lotId || '');
  const row = await io.fetch('Lot', lotId);
  if (!row) return { error: 'NotFound' };
  const page = await io.find('Bid', { where: { lotId }, order: 'at', limit: 100 });
  const bids = (page.items || []).slice().reverse();
  return { result: { lot: row, bids } };
}
