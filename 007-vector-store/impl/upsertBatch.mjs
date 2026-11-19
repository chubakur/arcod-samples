// Batch upsert: validate the whole batch, then write it.
//
// Dimension and metadata are checked before the first write, so a bad vector
// at index 40 does not leave 39 rows behind. Ids must be unique inside one
// batch; repeating an id is a client bug, not a last-write-wins merge.

const BT_TOKEN = /[^\p{L}\p{N}]+/gu;
const BT_LIMIT = 500;

function btCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function btHash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function btEmbed(text, dim) {
  const out = new Array(dim).fill(0);
  const tokens = String(text == null ? '' : text)
    .toLowerCase()
    .split(BT_TOKEN)
    .filter(Boolean);
  const grams = [];
  for (const token of tokens) {
    const padded = '^' + token + '$';
    for (let i = 0; i + 3 <= padded.length; i += 1) grams.push(padded.slice(i, i + 3));
  }
  const all = tokens.concat(grams);
  const tf = new Map();
  for (const item of all) tf.set(item, (tf.get(item) || 0) + 1);
  for (const [item, count] of tf) {
    const bucket = btHash(item) % dim;
    const sign = btHash('#' + item) % 2 === 0 ? 1 : -1;
    out[bucket] += sign * (1 + Math.log(count));
  }
  let norm = 0;
  for (const v of out) norm += v * v;
  norm = Math.sqrt(norm);
  if (norm > 0) for (let i = 0; i < out.length; i += 1) out[i] = out[i] / norm;
  return out;
}

function btDot(a, b) {
  let sum = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) sum += a[i] * b[i];
  return sum;
}

function btNorm(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * a[i];
  return Math.sqrt(sum);
}

function btScore(metric, a, b) {
  if (metric === 'l2') {
    let d = 0;
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i += 1) d += (a[i] - b[i]) * (a[i] - b[i]);
    return 1 / (1 + Math.sqrt(d));
  }
  const dot = btDot(a, b);
  if (metric === 'dot') return dot;
  const na = btNorm(a);
  const nb = btNorm(b);
  return na === 0 || nb === 0 ? 0 : dot / (na * nb);
}

async function btCentroids(io, collection) {
  const items = [];
  let cursor = null;
  do {
    const query = { where: { collection }, limit: 64 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('CentroidRec', query);
    for (const row of page.items || []) items.push(row);
    if (items.length >= 64) break;
    cursor = page.next || null;
  } while (cursor);
  return items;
}

async function btFind(io, collection, vid) {
  const page = await io.find('VectorRec', { where: { collection, vid }, limit: 1 });
  return (page.items || [])[0] || null;
}

async function btDropSlots(io, collection, vid) {
  let cursor = null;
  let removed = 0;
  do {
    const query = { where: { collection, vectorId: vid }, limit: 200 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('SlotRec', query);
    for (const row of page.items || []) {
      await io.remove('SlotRec', row.id);
      removed += 1;
    }
    cursor = page.next || null;
  } while (cursor);
  return removed;
}

function btBestSlot(centroids, metric, values) {
  let best = -1;
  let bestScore = -Infinity;
  for (const row of centroids) {
    const score = btScore(metric, values, (row.values || []).map(Number));
    if (best < 0 || score > bestScore) {
      best = Number(row.index);
      bestScore = score;
    }
  }
  return best;
}

export async function upsertBatch(input, io) {
  const collection = String(input.collection == null ? '' : input.collection);
  const coll = await io.fetch('Collection', collection);
  if (!coll) return { error: 'NotFound' };

  const list = Array.isArray(input.vectors) ? input.vectors : null;
  if (!list || list.length === 0 || list.length > BT_LIMIT) return { error: 'Invalid' };

  const dim = Number(coll.dim);
  const metric = coll.metric === 'dot' || coll.metric === 'l2' ? coll.metric : 'cosine';
  const seen = new Set();
  const prepared = [];

  for (const item of list) {
    const vid = String(item && item.id != null ? item.id : '').trim();
    if (!vid || vid.length > 200 || seen.has(vid)) return { error: 'Invalid' };
    seen.add(vid);

    const raw = Array.isArray(item.values) ? item.values.map(Number) : [];
    for (const v of raw) if (!Number.isFinite(v)) return { error: 'Invalid' };

    const text = String(item.text == null ? '' : item.text).trim();
    let values;
    if (raw.length === 0 && text) values = btEmbed(text, dim);
    else if (raw.length === dim) values = raw;
    else return { error: 'Invalid' };

    const meta = String(item.meta == null ? '{}' : item.meta);
    try {
      const parsed = JSON.parse(meta);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return { error: 'Invalid' };
    } catch (err) {
      return { error: 'Invalid' };
    }
    if (values.length !== dim) return { error: 'Invalid' };
    prepared.push({ vid, values, meta });
  }

  const centroids = coll.trained === true ? await btCentroids(io, collection) : [];
  const now = new Date().toISOString();
  let inserted = 0;
  let slotted = 0;
  const ids = [];

  for (const item of prepared) {
    const previous = await btFind(io, collection, item.vid);
    const version = previous ? Number(previous.version) + 1 : 1;
    const slots = centroids.length > 0 ? [btBestSlot(centroids, metric, item.values)] : [];

    if (previous) await btDropSlots(io, collection, item.vid);

    for (const slot of slots) {
      try {
        await io.insert('SlotRec', {
          id: collection + '|' + slot + '|' + item.vid,
          collection,
          slot,
          vectorId: item.vid,
        });
      } catch (err) {
        if (btCode(err) !== 'Conflict') throw err;
      }
    }

    if (previous) {
      await io.update('VectorRec', previous.id, {
        values: item.values,
        meta: item.meta,
        slots,
        version,
        updatedAt: now,
      });
    } else {
      await io.insert('VectorRec', {
        id: collection + '/' + item.vid,
        collection,
        vid: item.vid,
        values: item.values,
        meta: item.meta,
        slots,
        version,
        updatedAt: now,
      });
      inserted += 1;
    }
    slotted += slots.length;
    ids.push(item.vid);
  }

  await io.update('Collection', collection, {
    vectors: Math.max(0, Number(coll.vectors) + inserted),
    slots: Math.max(0, Number(coll.slots) + slotted),
    updatedAt: now,
  });

  return {
    result: {
      inserted,
      updated: prepared.length - inserted,
      slots: slotted,
      ids,
    },
  };
}
