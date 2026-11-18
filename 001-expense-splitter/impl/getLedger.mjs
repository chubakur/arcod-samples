export async function getLedger(input, io) {
  const groupId = String(input.groupId || '');
  if (!groupId) return { error: 'Invalid' };

  const rec = await io.load('g:' + groupId);
  if (!rec) return { error: 'NotFound' };

  const { group, expenses } = rec.b;
  const key = (m) => m.toLowerCase();
  const paid = new Map(group.members.map((m) => [key(m), 0]));
  const owed = new Map(group.members.map((m) => [key(m), 0]));

  for (const e of expenses) {
    paid.set(key(e.payer), (paid.get(key(e.payer)) || 0) + e.amount);
    const n = e.participants.length;
    const base = Math.floor(e.amount / n);
    let rest = e.amount - base * n;
    for (const p of e.participants) {
      const share = base + (rest > 0 ? 1 : 0);
      if (rest > 0) rest -= 1;
      owed.set(key(p), (owed.get(key(p)) || 0) + share);
    }
  }

  const balances = group.members.map((m) => {
    const p = paid.get(key(m)) || 0;
    const o = owed.get(key(m)) || 0;
    return { member: m, paid: p, owed: o, net: p - o };
  });

  return { result: { group, expenses, balances } };
}
