// The export row is the handle. The consumer owns the object and the status;
// the caller polls a real record instead of guessing an S3 key.
export async function exportTenant(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const member = await exMember(io, tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  if (!exStaff(member)) return { error: 'Forbidden' };
  const tenant = await io.fetch('Tenant', tenantId);
  if (!tenant) return { error: 'NotFound' };

  const now = new Date().toISOString();
  const row = {
    id: await io.new(),
    tenantId,
    status: 'queued',
    key: '',
    tickets: 0,
    messages: 0,
    bytes: 0,
    createdBy: actor.id,
    createdAt: now,
  };
  await io.insert('Export', row);
  await io.insert('Audit', {
    id: await io.new(),
    tenantId,
    ticketId: '',
    actor: actor.id,
    action: 'export.queued',
    detail: row.id,
    at: now,
  });
  await io.queuePublish('exportRun', row.id);
  return { result: row };
}

function exStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function exMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
