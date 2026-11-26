// Manual trigger. It only publishes; the job owns the version bump, so a
// request can never observe a half-built model.
export async function rebuildModel(input, io) {
  await io.queuePublish('snapshot', 'manual');
  return { result: await current(io) };
}

async function current(io) {
  const pointer = await io.load('feed:pointer');
  const p = pointer && pointer.b ? pointer.b : null;
  if (!p) return { version: 0, key: '', items: 0, pairs: 0, builtAt: '' };
  return {
    version: Number(p.version) || 0,
    key: String(p.key || ''),
    items: Number(p.items) || 0,
    pairs: Number(p.pairs) || 0,
    builtAt: String(p.builtAt || ''),
  };
}
