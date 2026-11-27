// An admin promotes or demotes a reviewer. The last admin cannot be demoted:
// the deployment would be left with nobody who can change policies.
export async function setRole(input, io) {
  const actor = await io.actor();
  const me = await srFindByUser(io, actor.id);
  if (!me || me.role !== 'admin') return { error: 'Forbidden' };

  const reviewerId = String(input.reviewerId || '');
  const role = String(input.role || '');
  if (['reviewer', 'senior', 'admin'].indexOf(role) < 0) return { error: 'Invalid' };

  const row = await io.fetch('Reviewer', reviewerId);
  if (!row) return { error: 'NotFound' };

  if (row.role === 'admin' && role !== 'admin') {
    const admins = await io.count('Reviewer', { where: { role: 'admin' } });
    if (Number(admins) <= 1) return { error: 'Conflict' };
  }

  await io.update('Reviewer', reviewerId, { role });
  return { result: { ...row, role } };
}

async function srFindByUser(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
