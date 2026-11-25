// Version bump: new events get the new number, old rows keep theirs, so an
// offline export can be replayed against the definition that was live then.
export async function publishVersion(input, io) {
  const name = String(input.name || '').trim();
  const description = String(input.description || '').trim();
  if (!name) return { error: 'NotFound' };

  const found = await io.find('Feature', { where: { name }, limit: 1 });
  const feature = (found.items || [])[0];
  if (!feature) return { error: 'NotFound' };

  const patch = {
    version: Number(feature.version || 1) + 1,
    updatedAt: new Date().toISOString(),
  };
  if (description) patch.description = description;
  await io.update('Feature', feature.id, patch);
  return { result: { ...feature, ...patch } };
}
