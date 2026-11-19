// Counters vs proof. The collection row is the fast path; a scan says what is
// actually in the store. When they disagree the response keeps both numbers.

async function stScan(io, entity, where, cap) {
  const items = [];
  let cursor = null;
  do {
    const query = { where, limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find(entity, query);
    for (const row of page.items || []) items.push(row);
    if (items.length >= cap) break;
    cursor = page.next || null;
  } while (cursor);
  return items;
}

export async function stats(input, io) {
  const collection = String(input.collection == null ? '' : input.collection);
  const coll = await io.fetch('Collection', collection);
  if (!coll) return { error: 'NotFound' };

  const vectors = await stScan(io, 'VectorRec', { collection }, 20000);
  const slots = await stScan(io, 'SlotRec', { collection }, 40000);
  const centroids = await stScan(io, 'CentroidRec', { collection }, 128);

  return {
    result: {
      collection,
      dim: Number(coll.dim),
      trained: coll.trained === true,
      vectors: Number(coll.vectors),
      scannedVectors: vectors.length,
      slots: Number(coll.slots),
      scannedSlots: slots.length,
      centroids: centroids.length,
    },
  };
}
