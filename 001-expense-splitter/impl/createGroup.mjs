export async function createGroup(input, io) {
  const name = String(input.name || '').trim();
  const currency = String(input.currency || '').trim().toUpperCase();
  const members = Array.isArray(input.members) ? input.members.map((m) => String(m).trim()) : [];

  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };
  if (members.length < 2) return { error: 'Invalid' };
  if (members.some((m) => m.length < 1 || m.length > 60)) return { error: 'Invalid' };
  if (new Set(members.map((m) => m.toLowerCase())).size !== members.length) return { error: 'Invalid' };
  if (!/^[A-Z]{3}$/.test(currency)) return { error: 'Invalid' };

  const id = await io.new();
  const group = {
    id,
    name,
    members,
    currency,
    createdAt: new Date().toISOString(),
  };
  await io.save('g:' + id, { b: { group, expenses: [] }, h: null });
  return { result: group };
}
