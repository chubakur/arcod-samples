export async function requests(input, io) {
  const limit = Number(input.limit || 50);
  const take = Number.isFinite(limit) && limit > 0 ? Math.min(limit, 200) : 50;
  const found = await io.find('ErasureRequest', { where: {}, limit: take });
  return { result: (found && found.items) || [] };
}
