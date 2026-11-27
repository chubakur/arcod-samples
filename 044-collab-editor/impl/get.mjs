function getReplay(content, op) {
  const body = String(content || '');
  const at = Math.min(Math.max(Number(op.pos) || 0, 0), body.length);
  if (op.kind === 'insert') return body.slice(0, at) + String(op.text || '') + body.slice(at);
  const count = String(op.text || '').length || 1;
  return body.slice(0, at) + body.slice(at + count);
}

export async function get(input, io) {
  const doc = await io.fetch('Doc', String(input.id || ''));
  if (!doc) return { error: 'NotFound' };
  const page = await io.find('Op', { where: { docId: doc.id }, order: 'at asc', limit: 5000 });
  const ops = page.items || [];
  return {
    result: { ...doc, content: ops.reduce(getReplay, ''), version: ops.length },
  };
}
