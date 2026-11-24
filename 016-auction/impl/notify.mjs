// At-least-once: the notification row is the idempotency key, so a redelivered
// message does not mail the seller twice.
export async function notify(input, io) {
  const lotId = String(input.lotId || '');
  const row = await io.fetch('Lot', lotId);
  if (!row) return;

  const page = await io.find('Notification', { where: { lotId }, limit: 50 });
  const done = new Set((page.items || []).map((item) => item.kind));
  const now = Math.floor(Date.now() / 1000);
  const sold = row.state === 'sold' && Number(row.highBidCents || 0) > 0;

  async function send(kind, to, subject, text) {
    if (done.has(kind)) return;
    await io.remote('Mailer', 'send', { from: 'auction@arcod.test', to, subject, text });
    await io.insert('Notification', { id: await io.new(), lotId, kind, to, subject, at: now });
    done.add(kind);
  }

  if (sold) {
    await send(
      'winner',
      'winner@arcod.test',
      'You won lot ' + row.title,
      row.title + ' is yours for ' + Number(row.highBidCents) / 100 + ' (bidder ' + row.highBidder + ')'
    );
  }
  const verdict = sold ? 'sold for ' + Number(row.highBidCents) / 100 : 'closed without a sale';
  await send('seller', row.sellerEmail, 'Lot ' + row.title + ' ' + verdict, verdict);
}
