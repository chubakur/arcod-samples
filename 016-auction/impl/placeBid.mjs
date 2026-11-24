// Three rules live here, not in the route: the minimum increment, "you cannot
// outbid yourself", and anti-sniping (a bid in the last 60 s moves the end by
// 120 s, at most three times). Money is cents, time is epoch seconds.
const MIN_INCREMENT = 100;
const SNIPE_WINDOW = 60;
const SNIPE_EXTENSION = 120;
const MAX_EXTENSIONS = 3;

export async function placeBid(input, io) {
  const lotId = String(input.lotId || '');
  const bidder = String(input.bidder || '').trim();
  const amount = Number(input.amountCents);
  if (!lotId || !bidder || !Number.isFinite(amount) || amount <= 0) return { error: 'Invalid' };

  const lot = await io.fetch('Lot', lotId);
  if (!lot) return { error: 'NotFound' };
  if (lot.state !== 'open') return { error: 'Conflict' };

  const now = Math.floor(Date.now() / 1000);
  const endsAt = Number(lot.endsAt);
  if (now >= endsAt) return { error: 'Conflict' };
  if (bidder === lot.highBidder) return { error: 'Conflict' };

  const high = Number(lot.highBidCents || 0);
  const floorCents = high > 0 ? high + MIN_INCREMENT : Number(lot.startCents);
  if (amount < floorCents) return { error: 'Invalid' };

  // The previous top bid stops being the winner; the row keeps its history.
  if (high > 0) {
    const prev = await io.find('Bid', { where: { lotId, state: 'accepted' }, limit: 10 });
    for (const row of prev.items || []) {
      await io.update('Bid', row.id, { state: 'outbid' });
    }
  }

  let nextEnds = endsAt;
  let extensions = Number(lot.extensions || 0);
  if (endsAt - now <= SNIPE_WINDOW && extensions < MAX_EXTENSIONS) {
    nextEnds = endsAt + SNIPE_EXTENSION;
    extensions += 1;
  }

  await io.update('Lot', lotId, {
    highBidCents: amount,
    highBidder: bidder,
    endsAt: nextEnds,
    extensions
  });
  const bid = {
    id: await io.new(),
    lotId,
    bidder,
    amountCents: amount,
    at: now,
    state: 'accepted'
  };
  await io.insert('Bid', bid);

  const updated = await io.fetch('Lot', lotId);
  const page = await io.find('Bid', { where: { lotId }, order: 'at', limit: 100 });
  const bids = (page.items || []).slice().reverse();
  return { result: { lot: updated, bids } };
}
