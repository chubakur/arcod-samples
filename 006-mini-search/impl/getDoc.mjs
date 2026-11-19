export async function getDoc(input, io) {
  const id = String(input.id == null ? '' : input.id);
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };
  return { result: doc };
}
