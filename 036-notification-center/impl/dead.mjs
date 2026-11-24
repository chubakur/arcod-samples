// The queue's dead letter is the operations surface: every message that used
// its whole retry budget is readable here, with the payload intact.
export async function dead(input, io) {
  const items = await io.queueDead('deliver');
  const ids = items.map((item) => (item && item.payload ? String(item.payload.deliveryId || '') : ''));
  const errors = items.map((item) => (item ? String(item.lastError || '') : ''));
  return { result: { topic: 'deliver', total: items.length, ids, errors } };
}
