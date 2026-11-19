// Upsert one vector.
//
// Three things have to agree: the vector row, the slot entries and the
// collection counters. The row is written last, so a crash between slot writes
// and the vector write leaves an unreachable slot entry, never a vector that
// no query can see. Replace deletes the old slots first: a stale slot only
// wastes a probe, it never changes a score.

const UP_TOKEN = /[^\p{L}\p{N}]+/gu;

function upCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function upFinite(values) {
  if (!Array.isArray(values)) return null;
  const out = new Array(values.length);
  for (let i = 0; i < values.length; i += 1) {
    const n = Number(values[i]);
    if (!Number.isFinite(n)) return null;
    out[i] = n;
  }
  return out;
}

function upHash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

// Deterministic hashing embedder. It is not a model: it maps lexical
// neighbourhoods (tokens, character trigrams) into dim buckets with signed
// accumulation. Good enough to demo the pipeline, honest about being lexical.
function upEmbed(text, dim) {
  const out = new Array(dim).fill(0);
  const tokens = String(text == null ? '' : text)
    .toLowerCase()
    .split(UP_TOKEN)
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
    const bucket = upHash(item) % dim;
    const sign = upHash('#' + item) % 2 === 0 ? 1 : -1;
    out[bucket] += sign * (1 + Math.log(count));
  }
  let norm = 0;
  for (const v of out) norm += v * v;
  norm = Math.sqrt(norm);
  if (norm > 0) for (let i = 0; i < out.length; i += 1) out[i] = out[i] / norm;
  return out;
}

function upDot(a, b) {
  let sum = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) sum += a[i] * b[i];
  return sum;
}

function upNorm(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * a[i];
  return Math.sqrt(sum);
}

// Same ordering as query: cosine and dot prefer large scores, l2 prefers a
// small distance, so it is converted to 1/(1+d).
function upScore(metric, a, b) {
  if (metric === 'l2') {
    let d = 0;
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i += 1) d += (a[i] - b[i]) * (a[i] - b[i]);
    d = Math.sqrt(d);
    return 1 / (1 + d);
  }
  const dot = upDot(a, b);
  if (metric === 'dot') return dot;
  const na = upNorm(a);
  const nb = upNorm(b);
  if (na === 0 || nb === 0) return 0;
  return dot / (na * nb);
}

async function upCentroids(io, collection, limit) {
  const items = [];
  let cursor = null;
  do {
    const query = { where: { collection }, limit: 64 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('CentroidRec', query);
    for (const row of page.items || []) items.push(row);
    if (items.length >= limit) break;
    cursor = page.next || null;
  } while (cursor);
  return items;
}

async function upFind(io, collection, vid) {
  const page = await io.find('VectorRec', { where: { collection, vid }, limit: 1 });
  return (page.items || [])[0] || null;
}

async function upDropSlots(io, collection, vid) {
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

async function upWriteSlots(io, collection, vid, slots) {
  for (const slot of slots) {
    try {
      await io.insert('SlotRec', {
        id: collection + '|' + slot + '|' + vid,
        collection,
        slot,
        vectorId: vid,
      });
    } catch (err) {
      // A rebuilt index may already hold this pair; same fact, one row.
      if (upCode(err) !== 'Conflict') throw err;
    }
  }
}

function upBestSlot(centroids, metric, values) {
  let best = -1;
  let bestScore = -Infinity;
  for (const row of centroids) {
    const score = upScore(metric, values, (row.values || []).map(Number));
    if (best < 0 || score > bestScore) {
      best = Number(row.index);
      bestScore = score;
    }
  }
  return best;
}

export async function upsertVector(input, io) {
  const collection = String(input.collection == null ? '' : input.collection);
  const vid = String(input.id == null ? '' : input.id).trim();
  if (!vid || vid.length > 200) return { error: 'Invalid' };

  const coll = await io.fetch('Collection', collection);

  if (!coll) return { error: 'NotFound' };

  const dim = Number(coll.dim);
  const raw = upFinite(input.values == null ? [] : input.values);
  if (!raw) return { error: 'Invalid' };

  const text = String(input.text == null ? '' : input.text).trim();
  let values;
  if (raw.length === 0 && text) values = upEmbed(text, dim);
  else if (raw.length === 0) return { error: 'Invalid' };
  else values = raw;

  if (values.length !== dim) return { error: 'Invalid' };
  for (const v of values) if (!Number.isFinite(v)) return { error: 'Invalid' };

  const meta = String(input.meta == null ? '{}' : input.meta);
  try {
    const parsed = JSON.parse(meta);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { error: 'Invalid' };
    }
  } catch (err) {
    return { error: 'Invalid' };
  }

  const metric = coll.metric === 'dot' || coll.metric === 'l2' ? coll.metric : 'cosine';
  const centroids = coll.trained === true ? await upCentroids(io, collection, 64) : [];
  const slots = centroids.length > 0 ? [upBestSlot(centroids, metric, values)] : [];

  const previous = await upFind(io, collection, vid);
  const now = new Date().toISOString();
  const version = previous ? Number(previous.version) + 1 : 1;

  if (previous) {
    await upDropSlots(io, collection, vid);
  }

  await upWriteSlots(io, collection, vid, slots);

  const row = {
    id: collection + '/' + vid,
    collection,
    vid,
    values,
    meta,
    slots,
    version,
    updatedAt: now,
  };

  try {
    if (previous) {
      await io.update('VectorRec', previous.id, {
        values,
        meta,
        slots,
        version,
        updatedAt: now,
      });
    } else {
      await io.insert('VectorRec', row);
    }
  } catch (err) {
    if (upCode(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  const vectors = Math.max(0, Number(coll.vectors) + (previous ? 0 : 1));
  const slotTotal = Math.max(0, Number(coll.slots) - (previous ? (previous.slots || []).length : 0) + slots.length);
  await io.update('Collection', collection, {
    vectors,
    slots: slotTotal,
    updatedAt: now,
  });

  return {
    result: {
      id: vid,
      collection,
      version,
      slots,
      inserted: !previous,
      dim,
    },
  };
}
