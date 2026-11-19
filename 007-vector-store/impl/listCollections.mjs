// Collections are few; one page of 500 is plenty and the cap is explicit.

export async function listCollections(input, io) {
  const items = [];
  let cursor = null;
  do {
    const query = { limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Collection', query);
    for (const row of page.items || []) items.push(row);
    if (items.length >= 500) break;
    cursor = page.next || null;
  } while (cursor);

  items.sort((a, b) => String(a.name).localeCompare(String(b.name)));
  return {
    result: items.map((row) => ({
      name: row.name,
      dim: Number(row.dim),
      metric: row.metric,
      nlist: Number(row.nlist),
      nprobe: Number(row.nprobe),
      vectors: Number(row.vectors),
      slots: Number(row.slots),
      trained: row.trained === true,
      createdAt: row.createdAt,
    })),
  };
}
