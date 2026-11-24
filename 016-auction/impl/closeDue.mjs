// The tick that turns the clock into money: every open lot whose end has
// passed gets a verdict, and one queue message per lot wakes the mailer.
export async function closeDue(input, io) {
  const now = Math.floor(Date.now() / 1000);
  const page = await io.find('Lot', { where: { state: 'open' }, limit: 500 });
  let closed = 0;

  for (const row of page.items || []) {
    if (Number(row.endsAt) > now) continue;
    const high = Number(row.highBidCents || 0);
    const sold = high > 0 && high >= Number(row.reserveCents);
    await io.update('Lot', row.id, { state: sold ? 'sold' : 'unsold', closedAt: now });
    if (!sold) {
      const bids = await io.find('Bid', { where: { lotId: row.id, state: 'accepted' }, limit: 100 });
      for (const bid of bids.items || []) {
        await io.update('Bid', bid.id, { state: 'lost' });
      }
    }
    await io.queuePublish('notify', { lotId: row.id });
    closed += 1;
  }

  return { result: { ok: true, closed } };
}
