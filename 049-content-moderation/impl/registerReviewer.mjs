// The first caller bootstraps the platform as admin: an empty deployment has
// nobody who could grant the role, so the alternative is a seed script outside
// the model. A later caller may only self-register as a plain reviewer; an
// admin promotes him with setRole.
export async function registerReviewer(input, io) {
  const actor = await io.actor();
  const name = String(input.name || '').trim();
  const role = String(input.role || 'reviewer');

  if (!name || name.length > 80) return { error: 'Invalid' };
  if (['reviewer', 'senior', 'admin'].indexOf(role) < 0) return { error: 'Invalid' };

  const existing = await rrFind(io, actor.id);
  if (existing) return { result: existing };

  const page = await io.find('Reviewer', { limit: 1 });
  const first = (page.items || []).length === 0;
  if (!first && role !== 'reviewer') return { error: 'Forbidden' };

  const row = {
    id: await io.new(),
    userId: actor.id,
    name,
    role: first ? 'admin' : 'reviewer',
    createdAt: new Date().toISOString(),
  };
  try {
    await io.insert('Reviewer', row);
  } catch (error) {
    if (!rrConflict(error)) throw error;
    const again = await rrFind(io, actor.id);
    if (!again) throw error;
    return { result: again };
  }
  return { result: row };
}

async function rrFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}

function rrConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
