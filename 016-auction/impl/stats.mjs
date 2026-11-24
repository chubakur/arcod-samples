export async function stats(input, io) {
  const sold = await io.count('Lot', { where: { state: 'sold' } });
  const unsold = await io.count('Lot', { where: { state: 'unsold' } });
  const bidVolume = await io.aggregate('Bid', { field: 'amountCents', op: 'sum', where: { state: 'accepted' } });
  const notifications = await io.count('Notification', { where: {} });
  return { result: { closedLots: sold + unsold, bidVolume: bidVolume || 0, notifications } };
}
