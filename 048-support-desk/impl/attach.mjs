// The row is written after the object: a failed upload leaves no attachment
// that points at a missing key. Body bytes are strings in this build (#48).
export async function attach(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const name = String(input.name || '').trim();
  const content = String(input.content || '');

  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };
  const member = await atMember(io, row.tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  const staff = atStaff(member);
  if (!staff && row.requester !== actor.id) return { error: 'Forbidden' };
  if (!name || name.length > 120) return { error: 'Invalid' };
  if (content.length > 200000) return { error: 'Invalid' };

  const id = await io.new();
  const safe = name.replace(/[^A-Za-z0-9._-]/g, '_');
  const key = 'attachments/' + row.tenantId + '/' + ticketId + '/' + id + '-' + safe;
  await io.blobPut(key, content, 'text/plain; charset=utf-8');

  const now = new Date().toISOString();
  const attachment = {
    id,
    ticketId,
    tenantId: row.tenantId,
    name,
    size: new TextEncoder().encode(content).length,
    key,
    uploadedBy: actor.id,
    createdAt: now,
  };
  await io.insert('Attachment', attachment);
  await io.update('Ticket', ticketId, {
    attachmentCount: Number(row.attachmentCount || 0) + 1,
    updatedAt: now,
  });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    actor: actor.id,
    action: 'attachment.added',
    detail: name + ' (' + attachment.size + ' bytes)',
    at: now,
  });
  return { result: attachment };
}

function atStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function atMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
