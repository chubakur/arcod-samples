// Working hours are strings ("09:00") interpreted in the host's timezone.
// They stay plain text on the row: the scheduler resolves them to UTC instants
// per requested date, so a DST switch never rewrites stored data.
function addHostMinutes(hhmm) {
  const m = /^([01][0-9]|2[0-3]):([0-5][0-9])$/.exec(String(hhmm || '').trim());
  return m ? Number(m[1]) * 60 + Number(m[2]) : -1;
}

export async function addHost(input, io) {
  const name = String(input.name || '').trim();
  const email = String(input.email || '').trim().toLowerCase();
  const timezone = String(input.timezone || '').trim();
  const workStart = String(input.workStart || '09:00').trim();
  const workEnd = String(input.workEnd || '18:00').trim();
  const start = addHostMinutes(workStart);
  const end = addHostMinutes(workEnd);

  if (!name || !email.includes('@') || !timezone) return { error: 'Invalid' };
  if (start < 0 || end < 0 || end <= start) return { error: 'Invalid' };

  try {
    new Intl.DateTimeFormat('en-US', { timeZone: timezone }).format(new Date());
  } catch (error) {
    return { error: 'Invalid' };
  }

  const existing = await io.find('Host', { where: { email }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const host = {
    id: await io.new(),
    name,
    email,
    timezone,
    workStart,
    workEnd,
    createdAt: new Date().toISOString()
  };
  try {
    await io.insert('Host', host);
  } catch (error) {
    if (addHostIsConflict(error)) return { error: 'Conflict' };
    throw error;
  }
  return { result: host };
}

function addHostIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
