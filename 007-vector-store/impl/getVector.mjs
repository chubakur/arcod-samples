// Read one vector, including the slot the index currently believes it is in.
// stale slots after a crash are visible here, not silently corrected.

function gvFind(io, collection, vid) {
  return io.find('VectorRec', { where: { collection, vid }, limit: 1 });
}

export async function getVector(input, io) {
  const collection = String(input.collection == null ? '' : input.collection);
  const vid = String(input.id == null ? '' : input.id);
  const page = await gvFind(io, collection, vid);
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound' };
  return {
    result: {
      id: row.vid,
      collection: row.collection,
      values: (row.values || []).map(Number),
      meta: row.meta == null ? '{}' : row.meta,
      slots: (row.slots || []).map(Number),
      version: Number(row.version),
      updatedAt: row.updatedAt,
    },
  };
}
