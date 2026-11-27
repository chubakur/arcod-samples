export async function comments(input, io) {
  const id = String(input.id || '');
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };
  const page = await io.find('Comment', { where: { docId: id }, order: 'createdAt asc', limit: 200 });
  return { result: page.items || [] };
}
