export async function model(input, io) {
  const pointer = await io.load('feed:pointer');
  const p = pointer && pointer.b ? pointer.b : null;
  if (!p) return { result: { version: 0, key: '', items: 0, pairs: 0, builtAt: '' } };
  return {
    result: {
      version: Number(p.version) || 0,
      key: String(p.key || ''),
      items: Number(p.items) || 0,
      pairs: Number(p.pairs) || 0,
      builtAt: String(p.builtAt || ''),
    },
  };
}
