// Delete one vector. Slots go first: a slot entry without a vector is a probe
// that returns nothing, while a vector with stale slots is still reachable by
// its own slot — the wrong failure mode for a delete.

export async function deleteVector(input, io) {
  const collection = String(input.collection == null ? '' : input.collection);
  const vid = String(input.id == null ? '' : input.id);
  const coll = await io.fetch('Collection', collection);
  if (!coll) return { error: 'NotFound' };

  const page = await io.find('VectorRec', { where: { collection, vid }, limit: 1 });
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound' };

  let removed = 0;
  let cursor = null;
  do {
    const query = { where: { collection, vectorId: vid }, limit: 200 };
    if (cursor) query.cursor = cursor;
    const slots = await io.find('SlotRec', query);
    for (const slot of slots.items || []) {
      await io.remove('SlotRec', slot.id);
      removed += 1;
    }
    cursor = slots.next || null;
  } while (cursor);

  await io.remove('VectorRec', row.id);
  await io.update('Collection', collection, {
    vectors: Math.max(0, Number(coll.vectors) - 1),
    slots: Math.max(0, Number(coll.slots) - removed),
    updatedAt: new Date().toISOString(),
  });

  return {
    result: {
      id: vid,
      collection,
      deleted: true,
      slots: removed,
    },
  };
}
