// A document starts empty; the text is produced by the operation log from
// here on.
export async function create(input, io) {
  const title = String(input.title || '').trim();
  const owner = String(input.owner || '').trim();
  if (!title || title.length > 200) return { error: 'Invalid' };
  if (!owner || owner.length > 120) return { error: 'Invalid' };

  const now = new Date().toISOString();
  const doc = {
    id: await io.new(),
    title,
    owner,
    content: '',
    version: 0,
    snapshotKey: null,
    snapshotVersion: 0,
    createdAt: now,
    updatedAt: now,
  };
  await io.insert('Doc', doc);
  return { result: doc };
}
