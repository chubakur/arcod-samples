function lookupSubjectHash(email) {
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

export async function subject(input, io) {
  const email = String(input.subjectEmail || '').trim().toLowerCase();
  if (!email) return { error: 'Invalid' };
  const hash = lookupSubjectHash(email);

  const datasets = ['Customer', 'OrderNote', 'SupportTicket'];
  const remaining = [];
  for (const dataset of datasets) {
    const count = await io.count(dataset, { where: { subjectHash: hash } });
    remaining.push({ dataset, rows: Number(count || 0) });
  }

  const found = await io.find('ErasureRequest', { where: { subjectHash: hash }, limit: 50 });
  const rows = (found && found.items) || [];
  const active = rows.filter((row) => row.state !== 'certified' && row.state !== 'failed').length;
  return { result: { subjectHash: hash, remaining, requests: rows.length, active } };
}
