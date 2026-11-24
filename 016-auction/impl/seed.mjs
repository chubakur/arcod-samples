export async function seed(input, io) {
  const now = Math.floor(Date.now() / 1000);
  const rows = [
    { title: 'Vintage poster', seller: 'anna', sellerEmail: 'anna@arcod.test', startCents: 500, reserveCents: 2000 },
    { title: 'Broken radio', seller: 'boris', sellerEmail: 'boris@arcod.test', startCents: 100, reserveCents: 100 }
  ];
  for (const row of rows) {
    await io.insert('Lot', {
      id: await io.new(),
      title: row.title,
      seller: row.seller,
      sellerEmail: row.sellerEmail,
      startCents: row.startCents,
      reserveCents: row.reserveCents,
      endsAt: now + 3600,
      state: 'open',
      highBidCents: 0,
      highBidder: '',
      extensions: 0,
      closedAt: null
    });
  }
  return { result: { ok: true, closed: 0 } };
}
