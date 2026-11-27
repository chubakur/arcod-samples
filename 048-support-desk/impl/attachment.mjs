// Bytes come from S3, not from the row: the metadata is only a pointer.
export async function attachment(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const attachmentId = String(input.attachmentId || '');

  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };
  const member = await afMember(io, row.tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  if (!afStaff(member) && row.requester !== actor.id) return { error: 'Forbidden' };

  const meta = await io.fetch('Attachment', attachmentId);
  if (!meta || meta.ticketId !== ticketId) return { error: 'NotFound' };
  const content = await io.blobGet(meta.key);
  return {
    result: {
      name: meta.name,
      content: content == null ? '' : String(content),
      bytes: Number(meta.size) || 0,
    },
  };
}

function afStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function afMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
