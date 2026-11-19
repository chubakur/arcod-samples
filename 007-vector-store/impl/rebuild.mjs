// Build the inverted file.
//
// k-means with deterministic seeding (first id, then farthest point), six
// passes, empty clusters keep their previous centroid. Small on purpose: the
// point of the example is that a build is a separate, repeatable step whose
// result is visible, not that it scales to millions of vectors.
//
// Training samples at most 2000 vectors and assigns at most 5000; both caps
// are reported (assigned) so nobody mistakes a truncated build for a full one.

const RB_TRAIN_CAP = 2000;
const RB_ASSIGN_CAP = 5000;
const RB_ITER = 6;

function rbDot(a, b) {
  let sum = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) sum += a[i] * b[i];
  return sum;
}

function rbNorm(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * a[i];
  return Math.sqrt(sum);
}

function rbScore(metric, a, b) {
  if (metric === 'l2') {
    let d = 0;
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i += 1) d += (a[i] - b[i]) * (a[i] - b[i]);
    return 1 / (1 + Math.sqrt(d));
  }
  const dot = rbDot(a, b);
  if (metric === 'dot') return dot;
  const na = rbNorm(a);
  const nb = rbNorm(b);
  return na === 0 || nb === 0 ? 0 : dot / (na * nb);
}

async function rbScan(io, entity, where, cap) {
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

function rbCentroidOf(rows, dim) {
  const out = new Array(dim).fill(0);
  let n = 0;
  for (const row of rows) {
    const values = (row.values || []).map(Number);
    for (let i = 0; i < dim; i += 1) out[i] += values[i] || 0;
    n += 1;
  }
  if (n > 0) for (let i = 0; i < dim; i += 1) out[i] = out[i] / n;
  return out;
}

export async function rebuild(input, io) {
  const started = Date.now();
  const collection = String(input.collection == null ? '' : input.collection);
  const coll = await io.fetch('Collection', collection);
  if (!coll) return { error: 'NotFound' };

  const dim = Number(coll.dim);
  const metric = coll.metric === 'dot' || coll.metric === 'l2' ? coll.metric : 'cosine';
  const nlist = Math.max(1, Math.min(64, Number(coll.nlist)));

  const rows = await rbScan(io, 'VectorRec', { collection }, RB_ASSIGN_CAP);
  if (rows.length === 0) return { error: 'Invalid' };

  const sorted = rows.slice().sort((a, b) => String(a.vid).localeCompare(String(b.vid)));
  const sample = sorted.slice(0, RB_TRAIN_CAP).map((row) => (row.values || []).map(Number));
  const k = Math.max(1, Math.min(nlist, sample.length));

  // Seeding: the first sampled vector, then the one least similar to all
  // chosen so far. Deterministic because the sample order is.
  const centroids = [sample[0].slice()];
  while (centroids.length < k) {
    let best = -1;
    let bestScore = Infinity;
    for (let i = 0; i < sample.length; i += 1) {
      let worst = -Infinity;
      for (const centroid of centroids) {
        const s = rbScore(metric, sample[i], centroid);
        if (s > worst) worst = s;
      }
      if (worst < bestScore) {
        bestScore = worst;
        best = i;
      }
    }
    if (best < 0) break;
    centroids.push(sample[best].slice());
  }

  let iterations = 0;
  for (let step = 0; step < RB_ITER; step += 1) {
    const groups = centroids.map(() => []);
    for (let i = 0; i < sample.length; i += 1) {
      let pick = 0;
      let pickScore = -Infinity;
      for (let c = 0; c < centroids.length; c += 1) {
        const s = rbScore(metric, sample[i], centroids[c]);
        if (s > pickScore) {
          pickScore = s;
          pick = c;
        }
      }
      groups[pick].push(i);
    }
    for (let c = 0; c < centroids.length; c += 1) {
      if (groups[c].length === 0) continue;
      const next = new Array(dim).fill(0);
      for (const index of groups[c]) {
        const values = sample[index];
        for (let d = 0; d < dim; d += 1) next[d] += values[d] || 0;
      }
      for (let d = 0; d < dim; d += 1) next[d] = next[d] / groups[c].length;
      centroids[c] = next;
    }
    iterations += 1;
  }

  // Replace the old centroids.
  const oldCentroids = await rbScan(io, 'CentroidRec', { collection }, 128);
  for (const row of oldCentroids) await io.remove('CentroidRec', row.id);

  const now = new Date().toISOString();
  const counts = new Array(centroids.length).fill(0);
  for (let c = 0; c < centroids.length; c += 1) {
    await io.insert('CentroidRec', {
      id: collection + ':' + c,
      collection,
      index: c,
      values: centroids[c],
      count: 0,
      updatedAt: now,
    });
  }

  // Rewrite every slot entry; the old index is not merged with the new one.
  const oldSlots = await rbScan(io, 'SlotRec', { collection }, RB_ASSIGN_CAP * 4);
  for (const row of oldSlots) await io.remove('SlotRec', row.id);

  let assigned = 0;
  let slots = 0;
  for (const row of rows) {
    const values = (row.values || []).map(Number);
    let pick = 0;
    let pickScore = -Infinity;
    for (let c = 0; c < centroids.length; c += 1) {
      const s = rbScore(metric, values, centroids[c]);
      if (s > pickScore) {
        pickScore = s;
        pick = c;
      }
    }
    counts[pick] += 1;
    try {
      await io.insert('SlotRec', {
        id: collection + '|' + pick + '|' + row.vid,
        collection,
        slot: pick,
        vectorId: row.vid,
      });
      slots += 1;
    } catch (err) {
      // A concurrent upsert may have written the same pair already.
      const code = (err && (err.error || err.code || err.name)) || '';
      if (code !== 'Conflict') throw err;
    }
    await io.update('VectorRec', row.id, { slots: [pick] });
    assigned += 1;
  }

  for (let c = 0; c < centroids.length; c += 1) {
    await io.update('CentroidRec', collection + ':' + c, { count: counts[c] });
  }

  await io.update('Collection', collection, {
    trained: true,
    nlist: centroids.length,
    slots,
    updatedAt: now,
  });

  return {
    result: {
      collection,
      centroids: centroids.length,
      assigned,
      slots,
      iterations,
      tookMs: Date.now() - started,
    },
  };
}
