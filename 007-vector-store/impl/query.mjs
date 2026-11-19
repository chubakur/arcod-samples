// Query the store.
//
// Two paths, one answer shape:
//   * index: probe the nprobe nearest centroids, read their slot entries,
//     fetch only those vectors, re-rank exactly.
//   * scan: touch every vector in the collection (untrained, exact=true, or
//     the probes produced fewer than k hits after filtering).
// The response says which path ran, how many slots were probed and how many
// vectors were actually scored. "approximate" is a fact, not a disclaimer.

const QY_TOKEN = /[^\p{L}\p{N}]+/gu;

function qyHash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function qyEmbed(text, dim) {
  const out = new Array(dim).fill(0);
  const tokens = String(text == null ? '' : text)
    .toLowerCase()
    .split(QY_TOKEN)
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
    const bucket = qyHash(item) % dim;
    const sign = qyHash('#' + item) % 2 === 0 ? 1 : -1;
    out[bucket] += sign * (1 + Math.log(count));
  }
  let norm = 0;
  for (const v of out) norm += v * v;
  norm = Math.sqrt(norm);
  if (norm > 0) for (let i = 0; i < out.length; i += 1) out[i] = out[i] / norm;
  return out;
}

function qyDot(a, b) {
  let sum = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) sum += a[i] * b[i];
  return sum;
}

function qyNorm(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * a[i];
  return Math.sqrt(sum);
}

// score is always "larger is better"; distance keeps the metric's own meaning.
function qyMeasure(metric, a, b) {
  if (metric === 'l2') {
    let d = 0;
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i += 1) d += (a[i] - b[i]) * (a[i] - b[i]);
    d = Math.sqrt(d);
    return { score: 1 / (1 + d), distance: d };
  }
  const dot = qyDot(a, b);
  if (metric === 'dot') return { score: dot, distance: -dot };
  const na = qyNorm(a);
  const nb = qyNorm(b);
  const cos = na === 0 || nb === 0 ? 0 : dot / (na * nb);
  return { score: cos, distance: 1 - cos };
}

function qyNumeric(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function qyValue(raw) {
  const text = String(raw == null ? '' : raw).trim();
  if (text.length >= 2 && (text[0] === '"' || text[0] === "'") && text[text.length - 1] === text[0]) {
    return { kind: 'string', value: text.slice(1, -1) };
  }
  if (/^-?\d+(\.\d+)?$/.test(text)) {
    return { kind: 'number', value: Number(text) };
  }
  return { kind: 'string', value: text };
}

function qyLookup(meta, path) {
  const parts = String(path).split('.');
  let cur = meta;
  for (const part of parts) {
    if (cur === null || typeof cur !== 'object' || Array.isArray(cur)) return undefined;
    cur = cur[part];
  }
  return cur;
}

function qyCompare(actual, op, expected) {
  if (op === 'in' || op === 'not in') {
    const inside = expected.some((item) => String(actual) === String(item.value));
    return op === 'in' ? inside : !inside;
  }
  if (actual === undefined || actual === null) return false;
  if (expected.kind === 'number' && qyNumeric(actual)) {
    const a = actual;
    const b = expected.value;
    if (op === '=') return a === b;
    if (op === '!=') return a !== b;
    if (op === '>') return a > b;
    if (op === '>=') return a >= b;
    if (op === '<') return a < b;
    if (op === '<=') return a <= b;
    return false;
  }
  const a = String(actual);
  const b = String(expected.value);
  if (op === '=') return a === b;
  if (op === '!=') return a !== b;
  if (op === '>') return a > b;
  if (op === '>=') return a >= b;
  if (op === '<') return a < b;
  if (op === '<=') return a <= b;
  return false;
}

// filter grammar: "tag=red AND year>=2020", "kind in (a, b)", no parentheses.
// A clause the parser does not understand is an Invalid request, never a
// silently ignored filter.
function qyParseFilter(expr) {
  const raw = String(expr == null ? '' : expr).trim();
  if (!raw) return { ok: true, test: () => true };

  const clauses = raw.split(/\s+AND\s+/i).map((s) => s.trim()).filter(Boolean);
  const tests = [];
  for (const clause of clauses) {
    const list = clause.match(/^([A-Za-z0-9_.]+)\s+(not\s+in|in)\s*\((.*)\)$/i);
    if (list) {
      const path = list[1];
      const op = list[2].toLowerCase().replace(/\s+/g, ' ');
      const values = list[3].split(',').map((s) => qyValue(s)).filter((v) => v.value !== '');
      tests.push((meta) => values.length === 0 ? op === 'not in' : qyCompare(qyLookup(meta, path), op, values));
      continue;
    }
    const cmp = clause.match(/^([A-Za-z0-9_.]+)\s*(>=|<=|!=|=|>|<)\s*(.+)$/);
    if (!cmp) return { ok: false };
    const path = cmp[1];
    const op = cmp[2];
    const value = qyValue(cmp[3]);
    tests.push((meta) => qyCompare(qyLookup(meta, path), op, value));
  }
  return { ok: true, test: (meta) => tests.every((fn) => fn(meta)) };
}

async function qyScan(io, entity, where, cap) {
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

async function qyCentroids(io, collection) {
  return qyScan(io, 'CentroidRec', { collection }, 128);
}

async function qySlotVids(io, collection, probed, cap) {
  const vids = new Set();
  for (const slot of probed) {
    let cursor = null;
    do {
      const query = { where: { collection, slot }, limit: 500 };
      if (cursor) query.cursor = cursor;
      const page = await io.find('SlotRec', query);
      for (const row of page.items || []) vids.add(String(row.vectorId));
      if (vids.size >= cap) return [...vids];
      cursor = page.next || null;
    } while (cursor);
  }
  return [...vids];
}

async function qyFetch(io, collection, vids, cap) {
  const rows = new Map();
  for (let i = 0; i < vids.length; i += 100) {
    const chunk = vids.slice(i, i + 100);
    let cursor = null;
    do {
      const query = { where: { collection, vid: { in: chunk } }, limit: 100 };
      if (cursor) query.cursor = cursor;
      const page = await io.find('VectorRec', query);
      for (const row of page.items || []) rows.set(String(row.vid), row);
      cursor = page.next || null;
    } while (cursor);
    if (rows.size >= cap) break;
  }
  return [...rows.values()];
}

function qyMeta(row) {
  try {
    const parsed = JSON.parse(row.meta == null ? '{}' : row.meta);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (err) {
    return {};
  }
}

export async function query(input, io) {
  const started = Date.now();
  const collection = String(input.collection == null ? '' : input.collection);
  const coll = await io.fetch('Collection', collection);
  if (!coll) return { error: 'NotFound' };

  const k = Number(input.k == null ? 5 : input.k);
  if (!Number.isInteger(k) || k < 1 || k > 100) return { error: 'Invalid' };

  const exact = input.exact === true;
  const includeValues = input.includeValues === true;
  const dim = Number(coll.dim);
  const metric = coll.metric === 'dot' || coll.metric === 'l2' ? coll.metric : 'cosine';

  const raw = Array.isArray(input.vector) ? input.vector : [];
  const text = String(input.text == null ? '' : input.text).trim();
  if (raw.length > 0 && text) return { error: 'Invalid' };
  if (raw.length === 0 && !text) return { error: 'Invalid' };

  let qv;
  if (raw.length > 0) {
    qv = raw.map(Number);
    if (qv.length !== dim) return { error: 'Invalid' };
    for (const v of qv) if (!Number.isFinite(v)) return { error: 'Invalid' };
  } else {
    qv = qyEmbed(text, dim);
  }

  const filter = qyParseFilter(input.filter);
  if (!filter.ok) return { error: 'Invalid' };

  const requested = Number(input.nprobe == null ? 0 : input.nprobe);
  if (!Number.isInteger(requested) || requested < 0 || requested > 64) return { error: 'Invalid' };

  let probed = [];
  if (!exact && coll.trained === true) {
    const centroids = await qyCentroids(io, collection);
    const ranked = centroids
      .map((row) => ({ index: Number(row.index), score: qyMeasure(metric, qv, (row.values || []).map(Number)).score }))
      .sort((a, b) => (b.score - a.score) || (a.index - b.index));
    const take = requested > 0 ? Math.min(requested, ranked.length) : Math.min(Number(coll.nprobe), ranked.length);
    probed = ranked.slice(0, take).map((row) => row.index).sort((a, b) => a - b);
  }

  const CAP = 20000;
  let rows = [];
  let path = 'scan';
  let scanned = 0;

  if (probed.length > 0) {
    const vids = await qySlotVids(io, collection, probed, CAP);
    rows = await qyFetch(io, collection, vids, CAP);
    path = 'index';
    scanned = rows.length;
  } else {
    // Untrained collection or exact=true: the scan is the answer.
    rows = await qyScan(io, 'VectorRec', { collection }, CAP);
    path = 'scan';
    scanned = rows.length;
  }

  let hits = qyRank(rows, qv, metric, filter, k, includeValues);
  if (path === 'index' && hits.length < k) {
    // The probes did not cover the answer: pay for the scan and say so.
    rows = await qyScan(io, 'VectorRec', { collection }, CAP);
    path = 'scan';
    scanned = rows.length;
    hits = qyRank(rows, qv, metric, filter, k, includeValues);
  }

  return {
    result: {
      collection,
      metric,
      k,
      probedSlots: probed,
      candidates: rows.length,
      scanned,
      exact: path === 'scan',
      tookMs: Date.now() - started,
      hits,
    },
  };
}

function qyRank(rows, qv, metric, filter, k, includeValues) {
  const scored = [];
  for (const row of rows) {
    const meta = qyMeta(row);
    if (!filter.test(meta)) continue;
    const values = (row.values || []).map(Number);
    const measured = qyMeasure(metric, qv, values);
    scored.push({
      id: String(row.vid),
      score: Math.round(measured.score * 1000000) / 1000000,
      distance: Math.round(measured.distance * 1000000) / 1000000,
      meta: row.meta == null ? '{}' : row.meta,
      values: includeValues ? values : [],
    });
  }
  scored.sort((a, b) => (b.score - a.score) || a.id.localeCompare(b.id));
  return scored.slice(0, k);
}
