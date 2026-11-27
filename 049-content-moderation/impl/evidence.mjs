// The screening decision is reproducible: the snapshot in S3 holds the policy
// version, the score, the matched terms and the links that produced it.
export async function evidence(input, io) {
  const actor = await io.actor();
  const me = await evFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const itemId = String(input.itemId || '');
  const row = await io.fetch('Item', itemId);
  if (!row) return { error: 'NotFound' };
  if (!row.evidenceKey) return { error: 'Conflict' };

  const content = await io.blobGet(row.evidenceKey);
  const text = content == null ? '' : String(content);
  return {
    result: {
      key: row.evidenceKey,
      content: text,
      bytes: new TextEncoder().encode(text).length,
    },
  };
}

async function evFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
