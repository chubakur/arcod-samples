// Demo PII: two subjects, three tables. Seeded through the API so a smoke run
// starts from a known state instead of a hand-written SQL script.
const PEOPLE = [
  {
    email: 'alice@example.com',
    name: 'Alice Ivanova',
    plan: 'pro',
    notes: ['Prefers email', 'Called about invoice 41'],
    tickets: ['Cannot log in', 'Refund question']
  },
  {
    email: 'bob@example.com',
    name: 'Bob Petrov',
    plan: 'free',
    notes: ['Asked for a demo'],
    tickets: ['Feature request']
  }
];

function seedSubjectHash(email) {
  const salted = 'arcod-demo-v1|' + email;
  let h1 = 0x811c9dc5;
  let h2 = 0x1000193;
  for (let i = 0; i < salted.length; i += 1) {
    const code = salted.charCodeAt(i);
    h1 = Math.imul(h1 ^ code, 0x01000193) >>> 0;
    h2 = Math.imul(h2 + code, 0x85ebca6b) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

export async function seed(input, io) {
  const existing = await io.count('Customer', { where: {} });
  if (Number(existing || 0) > 0) return { result: { ok: true, queued: 0 } };

  const now = new Date().toISOString();
  for (const person of PEOPLE) {
    const hash = seedSubjectHash(person.email);
    const customerId = await io.new();
    await io.insert('Customer', {
      id: customerId,
      subjectHash: hash,
      email: person.email,
      name: person.name,
      plan: person.plan,
      createdAt: now
    });
    for (const body of person.notes) {
      await io.insert('OrderNote', {
        id: await io.new(),
        customerId,
        subjectHash: hash,
        body,
        createdAt: now
      });
    }
    for (const subject of person.tickets) {
      await io.insert('SupportTicket', {
        id: await io.new(),
        subjectHash: hash,
        subject,
        body: 'ticket body',
        status: 'open',
        createdAt: now
      });
    }
  }
  return { result: { ok: true, queued: 1 } };
}
