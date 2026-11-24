// A template code is the campaign's foreign key, so it is unique by contract.
// Conflict is a real answer here, not an internal exception.
export async function createTemplate(input, io) {
  const code = String(input.code || '').trim().toLowerCase();
  const name = String(input.name || '').trim();
  const subject = String(input.subject || '').trim();
  const body = String(input.body || '').trim();
  if (!code || !name || !subject || !body) return { error: 'Invalid' };
  if (!/^[a-z0-9][a-z0-9-]{1,40}$/.test(code)) return { error: 'Invalid' };

  const existing = await io.find('Template', { where: { code }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const template = {
    id: await io.new(),
    code,
    name,
    subject,
    body,
    createdAt: Date.now(),
    active: true,
  };
  await io.insert('Template', template);
  return { result: template };
}
