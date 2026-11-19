// Create a collection. Dimension and metric are decided here and never move:
// a running index cannot be resized without a rebuild, and mixing metrics in
// one collection would make scores incomparable.

const CC_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$/;
const CC_METRICS = new Set(['cosine', 'dot', 'l2']);

function ccCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

export async function createCollection(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const dim = Number(input.dim);
  const metric = String(input.metric == null ? 'cosine' : input.metric).toLowerCase();
  const nlist = Number(input.nlist == null ? 8 : input.nlist);
  const nprobe = Number(input.nprobe == null ? 2 : input.nprobe);

  if (!CC_NAME.test(name)) return { error: 'Invalid' };
  if (!Number.isInteger(dim) || dim < 1 || dim > 1024) return { error: 'Invalid' };
  if (!CC_METRICS.has(metric)) return { error: 'Invalid' };
  if (!Number.isInteger(nlist) || nlist < 1 || nlist > 64) return { error: 'Invalid' };
  if (!Number.isInteger(nprobe) || nprobe < 1 || nprobe > nlist) return { error: 'Invalid' };

  const existing = await io.fetch('Collection', name);
  if (existing) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const row = {
    id: name,
    name,
    dim,
    metric,
    nlist,
    nprobe,
    vectors: 0,
    slots: 0,
    trained: false,
    createdAt: now,
    updatedAt: now,
  };

  try {
    await io.insert('Collection', row);
  } catch (err) {
    // Two create requests race on the same name: one wins, the other is a
    // conflict, never a duplicate collection.
    if (ccCode(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  return { result: { ...row } };
}
