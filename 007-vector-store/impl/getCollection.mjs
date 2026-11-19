// One collection, projected without its internal updatedAt noise? No: keep it
// honest. The row is the answer; the counters in it are what writes claimed.

export async function getCollection(input, io) {
  const name = String(input.name == null ? '' : input.name);
  const row = await io.fetch('Collection', name);
  if (!row) return { error: 'NotFound' };
  return {
    result: {
      name: row.name,
      dim: Number(row.dim),
      metric: row.metric,
      nlist: Number(row.nlist),
      nprobe: Number(row.nprobe),
      vectors: Number(row.vectors),
      slots: Number(row.slots),
      trained: row.trained === true,
      createdAt: row.createdAt,
    },
  };
}
