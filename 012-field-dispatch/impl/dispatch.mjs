// Queue consumer: pick a free technician in the ticket city and ask the
// routing service for an ETA. At-least-once, so the body is idempotent.
export async function dispatch(input, io) {
  const id = String(input.ticketId || '');
  if (!id) return { result: false };

  const ticket = await io.fetch('Ticket', id);
  if (!ticket) return { result: false };
  if (ticket.status !== 'queued') return { result: true };

  const found = await io.find('Tech', { where: { city: ticket.city }, limit: 100 });
  const candidates = (found.items || [])
    .filter((t) => t.active !== false)
    .filter((t) => String(t.skills || '').split(',').includes(ticket.category))
    .sort((a, b) => Number(a.load || 0) - Number(b.load || 0));

  const tech = candidates[0];
  if (!tech) {
    // Nobody on shift: the ticket stays queued for the operator, and the
    // message is acked instead of spinning in the retry loop.
    return { result: true };
  }

  let reply = null;
  try {
    reply = await io.remote('Router', 'offer', {
      ticketId: id,
      city: ticket.city,
      category: ticket.category,
      priority: ticket.priority,
    });
  } catch {
    return { result: false };
  }
  // io.remote answers with the HTTP envelope { status, body }.
  const ack = reply && reply.body ? reply.body : reply;
  if (!ack || ack.accepted !== true) return { result: true };

  const eta = Number(ack.eta == null ? 60 : ack.eta);
  await io.update('Ticket', id, {
    status: 'assigned',
    technicianId: tech.id,
    technician: tech.name,
    etaMinutes: eta,
  });
  await io.update('Tech', tech.id, { load: Number(tech.load || 0) + 1 });
  return { result: true };
}
