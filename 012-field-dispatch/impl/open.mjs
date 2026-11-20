const PRIORITY_HOURS = { 1: 4, 2: 12, 3: 48 };
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function open(input, io) {
  const customer = String(input.customer || '').trim();
  const email = String(input.email || '').trim();
  const city = String(input.city || '').trim();
  const address = String(input.address || '').trim();
  const category = String(input.category || '').trim().toLowerCase();
  const priority = Number(input.priority == null ? 2 : input.priority);

  if (!customer || !city || !address || !category) return { error: 'Invalid' };
  if (!EMAIL.test(email)) return { error: 'Invalid' };
  if (!PRIORITY_HOURS[priority]) return { error: 'Invalid' };

  const id = await io.new();
  const createdAt = new Date().toISOString();
  const dueAt = new Date(Date.now() + PRIORITY_HOURS[priority] * 3600 * 1000).toISOString();
  const code = 'DSP-' + id.replace(/-/g, '').slice(0, 8).toUpperCase();

  const ticket = {
    id,
    code,
    customer,
    email,
    city,
    address,
    category,
    priority,
    status: 'queued',
    createdAt,
    dueAt,
    technicianId: null,
    technician: null,
    etaMinutes: null,
    note: null,
    photoKeys: '',
    closedAt: null,
  };

  await io.insert('Ticket', ticket);
  // The dispatcher is a background consumer: HTTP returns as soon as the
  // ticket is durable, the assignment happens on the queue.
  await io.queuePublish('dispatch', id);
  return { result: ticket };
}
