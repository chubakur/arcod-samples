// A request is a hash and a fingerprint, nothing more. The demo hash is salted
// FNV-1a: the sandbox has no crypto module, and a real deployment would hash in
// the CRM that owns the address. What matters here is that the service can find
// every row of a subject without ever storing the address it came from.
function createSubjectHash(email) {
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

function mask(email) {
  const at = email.indexOf('@');
  if (at <= 0) return '***';
  return email.slice(0, 1) + '***@' + email.slice(at + 1);
}

export async function create(input, io) {
  const email = String(input.subjectEmail || '').trim().toLowerCase();
  const reason = String(input.reason || '').trim() || 'data-subject request';
  if (email.length < 5 || email.length > 254 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { error: 'Invalid' };
  }

  const hash = createSubjectHash(email);

  // One live request per subject. A certified request is history: the next ask
  // creates a new one, because the subject may have come back after new data.
  const found = await io.find('ErasureRequest', { where: { subjectHash: hash }, limit: 50 });
  const rows = (found && found.items) || [];
  const live = rows.find((row) => row.state === 'pending' || row.state === 'erasing' || row.state === 'erased');
  if (live) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const record = {
    id: await io.new(),
    subjectHash: hash,
    subjectLabel: mask(email),
    reason,
    state: 'pending',
    datasets: 3,
    rowsDeleted: 0,
    attempts: 0,
    reportKey: '',
    certificate: '',
    createdAt: now,
    updatedAt: now
  };
  await io.insert('ErasureRequest', record);
  await io.queuePublish('erase', { requestId: record.id });
  return { result: record };
}
