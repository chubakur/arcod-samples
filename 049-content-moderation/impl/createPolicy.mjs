// A policy change is a new immutable version: the old row is deactivated but
// kept, and rescreen re-reads content that an older policy auto-approved.
export async function createPolicy(input, io) {
  const actor = await io.actor();
  const me = await cpFind(io, actor.id);
  if (!me || me.role !== 'admin') return { error: 'Forbidden' };

  const name = String(input.name || '').trim();
  const terms = String(input.terms || '').trim();
  const linkWeight = Number(input.linkWeight);
  const threshold = Number(input.threshold);

  if (!name || name.length > 120) return { error: 'Invalid' };
  if (!terms || terms.length > 2000) return { error: 'Invalid' };
  if (!Number.isInteger(linkWeight) || linkWeight < 0 || linkWeight > 100) return { error: 'Invalid' };
  if (!Number.isInteger(threshold) || threshold < 1 || threshold > 100) return { error: 'Invalid' };

  const lastPage = await io.find('Policy', { order: 'version desc', limit: 1 });
  const last = (lastPage.items || [])[0] || null;
  const version = last ? Number(last.version) + 1 : 1;

  const activePage = await io.find('Policy', { where: { active: true }, limit: 50 });
  for (const old of activePage.items || []) {
    await io.update('Policy', old.id, { active: false });
  }

  const row = {
    id: await io.new(),
    version,
    name,
    terms,
    linkWeight,
    threshold,
    active: true,
    createdBy: actor.id,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Policy', row);
  await io.queuePublish('rescreen', row.id);
  return { result: row };
}

async function cpFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
