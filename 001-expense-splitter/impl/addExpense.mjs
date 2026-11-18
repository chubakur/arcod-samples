export async function addExpense(input, io) {
  const groupId = String(input.groupId || '');
  const payer = String(input.payer || '').trim();
  const amount = Number(input.amount);
  const participants = Array.isArray(input.participants)
    ? input.participants.map((m) => String(m).trim())
    : [];
  const note = input.note == null ? null : String(input.note);

  if (!groupId) return { error: 'Invalid' };
  if (!Number.isInteger(amount) || amount <= 0) return { error: 'Invalid' };
  if (participants.length < 1) return { error: 'Invalid' };
  if (note !== null && note.length > 500) return { error: 'Invalid' };

  const rec = await io.load('g:' + groupId);
  if (!rec) return { error: 'NotFound' };

  const { group, expenses } = rec.b;
  const known = new Set(group.members.map((m) => m.toLowerCase()));
  if (!known.has(payer.toLowerCase())) return { error: 'Invalid' };
  if (new Set(participants.map((m) => m.toLowerCase())).size !== participants.length) {
    return { error: 'Invalid' };
  }
  if (participants.some((m) => !known.has(m.toLowerCase()))) return { error: 'Invalid' };

  const expense = {
    id: await io.new(),
    payer,
    amount,
    participants,
    note,
    at: new Date().toISOString(),
  };
  expenses.push(expense);
  await io.save('g:' + groupId, { b: { group, expenses }, h: rec.h });
  return { result: expense };
}
