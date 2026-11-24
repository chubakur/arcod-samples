export async function mailbox(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Mailbox', id);
  if (!found) return { error: 'NotFound' };

  const routes = await io.count('Route', { where: { mailboxId: id } });
  const messages = await io.count('Message', { where: { mailboxId: id } });

  return {
    result: {
      id: found.id,
      address: found.address,
      cursor: String(found.cursor || '0'),
      createdAt: Number(found.createdAt || 0),
      routes: Number(routes),
      messages: Number(messages),
    },
  };
}
