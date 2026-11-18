// The audit trail: who took the number, when, and how it ended. Fence numbers
// only grow, so the newest row with the highest fence is the current grant.

export async function history(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const limit = input.limit == null ? 20 : Number(input.limit);
  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return { error: 'Invalid' };

  const page = await io.find('Trace', { where: { name }, order: 'at desc', limit });
  return { result: page && page.items ? page.items : [] };
}
