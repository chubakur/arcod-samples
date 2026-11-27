export async function revisions(input, io) {
  const id = String(input.id || '');
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };
  const page = await io.find('Revision', { where: { docId: id }, order: 'version asc', limit: 200 });
  return { result: page.items || [] };
}
