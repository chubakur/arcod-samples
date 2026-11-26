// Ingest one interaction.
//
// Idempotency is by clientEventId: the producer may retry a POST after a
// timeout. A hit returns the stored row and publishes nothing; a race between
// two first deliveries is caught by the unique index and re-read.
const WEIGHTS = { view: 1, cart: 2, buy: 3 };

export async function track(input, io) {
  const clientEventId = String(input.clientEventId || '').trim();
  const userId = String(input.userId || '').trim();
  const itemId = String(input.itemId || '').trim();
  const kind = String(input.kind || '').trim();

  if (!clientEventId || clientEventId.length > 120) return { error: 'Invalid' };
  if (!userId || userId.length > 120) return { error: 'Invalid' };
  if (!itemId) return { error: 'Invalid' };
  if (!Object.hasOwn(WEIGHTS, kind)) return { error: 'Invalid' };

  const seen = await io.find('Interaction', { where: { clientEventId }, limit: 1 });
  const already = (seen.items || [])[0];
  if (already) return { result: already };

  const item = await io.fetch('Item', itemId);
  if (!item || item.active === false) return { error: 'Invalid' };

  const row = {
    id: await io.new(),
    clientEventId,
    userId,
    itemId,
    kind,
    weight: WEIGHTS[kind],
    ts: new Date().toISOString(),
  };
  try {
    await io.insert('Interaction', row);
  } catch (error) {
    if (trackIsConflict(error)) {
      const again = await io.find('Interaction', { where: { clientEventId }, limit: 1 });
      const stored = (again.items || [])[0];
      if (stored) return { result: stored };
      return { error: 'Conflict' };
    }
    throw error;
  }

  // The publish rides the outbox of the same transaction as the insert: a row
  // without a queued recompute is impossible, a recompute without a row is
  // harmless (the job folds what it can see).
  await io.queuePublish('recompute', userId);
  return { result: row };
}

function trackIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
