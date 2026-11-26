// Read path: pointer -> snapshot in S3 -> join with catalogue -> filter seen.
//
// The snapshot is the only artefact the reader trusts; pair counts in SQL are
// the job's private state. Ordering is score desc, then id, so a smoke test can
// assert an exact order without a stable-sort surprise.
export async function feed(input, io) {
  const userId = String(input.userId || '').trim();
  let limit = Number(input.limit);
  if (!Number.isInteger(limit)) limit = 10;
  if (!userId) return { error: 'Invalid' };
  if (limit < 1 || limit > 50) return { error: 'Invalid' };

  const itemsPage = await io.find('Item', { where: { active: true }, limit: 1000 });
  const byId = new Map();
  for (const item of itemsPage.items || []) byId.set(String(item.id), item);

  const history = await io.find('Interaction', { where: { userId }, limit: 500 });
  const seen = new Set((history.items || []).map((row) => String(row.itemId)));

  const pointer = await io.load('feed:pointer');
  let model = null;
  if (pointer && pointer.b && pointer.b.key) {
    try {
      model = JSON.parse(String(await io.blobGet(String(pointer.b.key))));
    } catch {
      model = null;
    }
  }

  const scores = new Map();
  const reasons = new Map();

  if (model && model.neighbours) {
    for (const itemId of seen) {
      for (const pair of model.neighbours[itemId] || []) {
        const other = String(pair[0]);
        const count = Number(pair[1]) || 0;
        if (seen.has(other) || !byId.has(other)) continue;
        scores.set(other, (scores.get(other) || 0) + count);
        reasons.set(other, 'co-occur');
      }
    }
  }

  const popularity = model && Array.isArray(model.popularity) ? model.popularity : null;
  if (popularity) {
    for (const pair of popularity) {
      const id = String(pair[0]);
      if (seen.has(id) || !byId.has(id) || scores.has(id)) continue;
      // Popularity carries its own weight: a cold user is ranked by it.
      scores.set(id, Number(pair[1]) || 0);
      reasons.set(id, 'popular');
    }
  } else {
    // Cold start: no snapshot yet. Rank by raw interaction weight so a brand
    // new deployment still answers something usable.
    const recent = await io.find('Interaction', { limit: 2000 });
    for (const row of recent.items || []) {
      const id = String(row.itemId);
      if (seen.has(id) || !byId.has(id)) continue;
      scores.set(id, (scores.get(id) || 0) + (Number(row.weight) || 1));
      reasons.set(id, 'popular');
    }
  }

  const ranked = [...scores.entries()]
    .map(([itemId, score]) => ({
      itemId,
      title: String((byId.get(itemId) || {}).title || ''),
      score,
      reason: reasons.get(itemId),
    }))
    .sort((a, b) => b.score - a.score || a.itemId.localeCompare(b.itemId));

  return { result: ranked.slice(0, limit) };
}
