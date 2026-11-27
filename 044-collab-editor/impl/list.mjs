function listReplay(content, op) {
  const body = String(content || '');
  const at = Math.min(Math.max(Number(op.pos) || 0, 0), body.length);
  if (op.kind === 'insert') return body.slice(0, at) + String(op.text || '') + body.slice(at);
  const count = String(op.text || '').length || 1;
  return body.slice(0, at) + body.slice(at + count);
}

export async function list(input, io) {
  const limit = Math.min(Math.max(Number(input.limit) || 20, 1), 100);
  const page = await io.find('Doc', { order: 'updatedAt desc', limit });
  const docs = page.items || [];
  const rows = [];
  for (const doc of docs) {
    const ops = await io.find('Op', { where: { docId: doc.id }, order: 'at asc', limit: 5000 });
    const items = ops.items || [];
    rows.push({ ...doc, content: items.reduce(listReplay, ''), version: items.length });
  }
  return { result: rows };
}
