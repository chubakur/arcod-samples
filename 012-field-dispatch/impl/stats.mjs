export async function stats(input, io) {
  const city = String(input.city || '').trim();
  const where = city ? { city } : {};

  const open = await io.count('Ticket', { where: { ...where, status: 'queued' } });
  const assigned = await io.count('Ticket', { where: { ...where, status: 'assigned' } });
  const done = await io.count('Ticket', { where: { ...where, status: 'done' } });

  return { result: { city, open, assigned, done } };
}
