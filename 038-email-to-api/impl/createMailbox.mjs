// The address is the natural key: two mailboxes with the same address would
// split one inbox between them. The signing secret is generated here and
// shown exactly once.
function mailboxHex(bytes) {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function createMailbox(input, io) {
  const address = String(input.address || '').trim().toLowerCase().slice(0, 200);
  if (!address || address.indexOf('@') <= 0 || address.indexOf(' ') >= 0) {
    return { error: 'Invalid' };
  }

  const same = await io.find('Mailbox', { where: { address }, limit: 1 });
  if ((same.items || []).length > 0) return { error: 'Conflict' };

  const secret = mailboxHex(crypto.getRandomValues(new Uint8Array(24)));
  const mailbox = {
    id: await io.new(),
    address,
    secret,
    cursor: '0',
    active: true,
    createdAt: Date.now(),
  };
  await io.insert('Mailbox', mailbox);

  return {
    result: {
      id: mailbox.id,
      address: mailbox.address,
      secret: mailbox.secret,
      cursor: mailbox.cursor,
      createdAt: mailbox.createdAt,
    },
  };
}
