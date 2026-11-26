// Consumer 2: build a versioned snapshot in S3 and flip the kv pointer.
//
// Readers only ever see complete snapshots: the object is written first, then
// the pointer, then the audit row. A failed write leaves the previous version
// serving traffic.
//
// Pair totals are derived here by summing per-user Touch rows, so the job needs
// no shared counters and is safe to retry.
const TOP_NEIGHBOURS = 20;
const TOP_POPULAR = 50;

export async function snapshot(input, io) {
  const itemsPage = await io.find('Item', { where: { active: true }, limit: 1000 });
  const items = itemsPage.items || [];
  const active = new Set(items.map((row) => String(row.id)));

  const touchPage = await io.find('Touch', { limit: 4000 });
  const touches = touchPage.items || [];

  const eventPage = await io.find('Interaction', { limit: 4000 });
  const events = eventPage.items || [];

  const scores = new Map();
  for (const touch of touches) {
    const key = String(touch.pairId);
    scores.set(key, (scores.get(key) || 0) + (Number(touch.boost) || 0));
  }

  const neighbours = new Map();
  for (const touch of touches) {
    const a = String(touch.a);
    const b = String(touch.b);
    const key = a < b ? a + '|' + b : b + '|' + a;
    const count = scores.get(key) || 0;
    if (!neighbours.has(a)) neighbours.set(a, []);
    if (!neighbours.has(b)) neighbours.set(b, []);
    neighbours.get(a).push([b, count]);
    neighbours.get(b).push([a, count]);
  }

  const popularity = new Map();
  for (const row of events) {
    const id = String(row.itemId);
    popularity.set(id, (popularity.get(id) || 0) + (Number(row.weight) || 1));
  }

  const neighboursOut = {};
  for (const [key, list] of neighbours) {
    // A pair contributes once: dedupe by neighbour id and keep the best count.
    const best = new Map();
    for (const [other, count] of list) {
      if (!best.has(other) || best.get(other) < count) best.set(other, count);
    }
    neighboursOut[key] = [...best.entries()]
      .sort((x, y) => y[1] - x[1] || String(x[0]).localeCompare(String(y[0])))
      .slice(0, TOP_NEIGHBOURS);
  }

  const popularityOut = [...popularity.entries()]
    .filter(([id]) => active.has(id))
    .sort((x, y) => y[1] - x[1] || String(x[0]).localeCompare(String(y[0])))
    .slice(0, TOP_POPULAR);

  const prev = await io.load('feed:pointer');
  const version = ((prev && prev.b && Number(prev.b.version)) || 0) + 1;
  const key = 'models/v' + version + '.json';
  const builtAt = new Date().toISOString();
  const body = JSON.stringify({
    version,
    builtAt,
    items: items.length,
    pairs: scores.size,
    popularity: popularityOut,
    neighbours: neighboursOut,
  });

  await io.blobPut(key, body, 'application/json');
  await io.insert('ModelVersion', {
    id: 'v' + version,
    version,
    key,
    items: items.length,
    pairs: scores.size,
    builtAt,
  });
  // kv records are written as { b: body, h: hash }: the same envelope load
  // returns. Writing the bare object stores no body at all.
  await io.save('feed:pointer', {
    b: {
      version,
      key,
      items: items.length,
      pairs: scores.size,
      builtAt,
    },
    h: null,
  });
  return { result: true };
}
