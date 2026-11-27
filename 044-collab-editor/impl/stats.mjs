export async function stats(input, io) {
  const docs = await io.count('Doc');
  const ops = await io.count('Op');
  const comments = await io.count('Comment');
  const revisions = await io.count('Revision');
  return { result: { docs, ops, comments, revisions } };
}
