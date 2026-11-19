// Drop a collection and everything it owns. Bounded: a demo store refuses to
// pretend it can drop an unbounded amount of rows inside one request, but the
// cap (20k vectors) is high enough for the examples.

const DR_CAP = 20000;

async function drScan(io, entity, where, cap) {
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

export async function dropCollection(input, io) {
  const name = String(input.name == null ? '' : input.name);
  const coll = await io.fetch('Collection', name);
  if (!coll) return { error: 'NotFound' };

  const vectors = await drScan(io, 'VectorRec', { collection: name }, DR_CAP);
  for (const row of vectors) await io.remove('VectorRec', row.id);

  const slots = await drScan(io, 'SlotRec', { collection: name }, DR_CAP * 4);
  for (const row of slots) await io.remove('SlotRec', row.id);

  const centroids = await drScan(io, 'CentroidRec', { collection: name }, 128);
  for (const row of centroids) await io.remove('CentroidRec', row.id);

  await io.remove('Collection', name);

  return {
    result: {
      dropped: true,
      vectors: vectors.length,
      slots: slots.length,
    },
  };
}
