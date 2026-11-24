// Topic is what the subscriber sees; the two matchers are lowercase
// substrings so the rule set stays explainable in one line.
export async function createRoute(input, io) {
  const mailboxId = String(input.mailboxId || '');
  const topic = String(input.topic || '').trim().slice(0, 80);
  const fromContains = String(input.fromContains || '').trim().toLowerCase().slice(0, 200);
  const subjectContains = String(input.subjectContains || '').trim().toLowerCase().slice(0, 200);

  if (!topic) return { error: 'Invalid' };
  if (!fromContains && !subjectContains) return { error: 'Invalid' };

  const mailbox = await io.fetch('Mailbox', mailboxId);
  if (!mailbox) return { error: 'NotFound' };

  const same = await io.find('Route', { where: { mailboxId, topic }, limit: 1 });
  if ((same.items || []).length > 0) return { error: 'Conflict' };

  const route = {
    id: await io.new(),
    mailboxId,
    topic,
    fromContains,
    subjectContains,
    active: true,
    createdAt: Date.now(),
  };
  await io.insert('Route', route);
  return { result: route };
}
