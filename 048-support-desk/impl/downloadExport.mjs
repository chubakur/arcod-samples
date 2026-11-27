// A queued export has no key yet; reading it is a conflict, not a 404.
export async function downloadExport(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const exportId = String(input.exportId || '');
  const member = await deMember(io, tenantId, actor.id);
  if (!member || !deStaff(member)) return { error: 'Forbidden' };

  const row = await io.fetch('Export', exportId);
  if (!row || row.tenantId !== tenantId) return { error: 'NotFound' };
  if (row.status !== 'ready') return { error: 'Conflict' };

  const content = await io.blobGet(row.key);
  return {
    result: {
      key: row.key,
      content: content == null ? '' : String(content),
      bytes: Number(row.bytes) || 0,
    },
  };
}

function deStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function deMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
