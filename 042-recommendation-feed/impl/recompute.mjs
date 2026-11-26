// Consumer 1: fold one user's interactions into per-user pair evidence.
//
// Idempotent by construction: the row id is "user|min|max" and the write is an
// upsert of the boost. A retried job, or the same event twice, cannot inflate
// the count. Pair totals are summed at snapshot time instead of being kept as
// one shared counter (a read-modify-write the SQL store has no primitive for,
// chubakur/arcod#10).
const MAX_ITEMS = 60;
const MAX_PAIRS = 200;

export async function recompute(input, io) {
  const userId = String(input.userId || '');
  if (!userId) return { result: false };

  const page = await io.find('Interaction', { where: { userId }, limit: 500 });
  const weight = new Map();
  for (const row of page.items || []) {
    const id = String(row.itemId);
    weight.set(id, Math.max(weight.get(id) || 0, Number(row.weight) || 1));
  }

  const ids = [...weight.keys()].sort().slice(0, MAX_ITEMS);
  const now = new Date().toISOString();
  let touched = 0;

  for (let i = 0; i < ids.length && touched < MAX_PAIRS; i++) {
    for (let j = i + 1; j < ids.length && touched < MAX_PAIRS; j++) {
      const a = ids[i];
      const b = ids[j];
      const pairId = a + '|' + b;
      const id = userId + '|' + pairId;
      const boost = Math.min(weight.get(a), weight.get(b));
      const found = await io.find('Touch', { where: { id }, limit: 1 });
      const row = (found.items || [])[0];
      if (row) {
        if (Number(row.boost) < boost) await io.update('Touch', id, { boost, updatedAt: now });
      } else {
        try {
          await io.insert('Touch', { id, userId, pairId, a, b, boost, updatedAt: now });
        } catch (error) {
          const name = error && (error.error || error.name);
          if (name !== 'Conflict') throw error;
        }
      }
      touched++;
    }
  }
  return { result: true };
}
