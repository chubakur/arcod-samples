export async function report(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };

  const ticket = await io.fetch('Ticket', id);
  if (!ticket) return { error: 'NotFound' };

  const out = [];
  for (const key of String(ticket.photoKeys || '').split(',').filter(Boolean)) {
    const body = await io.blobGet('ticket/' + id + '/' + key);
    if (body != null) out.push(String(body));
  }
  return { result: out };
}
