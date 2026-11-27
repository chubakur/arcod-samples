// Slot discovery walks the guest's local day on a 15-minute grid and keeps a
// candidate only if the host is inside working hours *in the host's zone*.
// That is why the loop is in UTC: both zones are projections of the same
// instant, and no wall-clock arithmetic leaks across a DST boundary.
function slotsOffsetMs(tz, ms) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  });
  const out = {};
  for (const part of fmt.formatToParts(new Date(ms))) {
    if (part.type !== 'literal') out[part.type] = part.value;
  }
  const asUtc = Date.UTC(
    Number(out.year),
    Number(out.month) - 1,
    Number(out.day),
    Number(out.hour),
    Number(out.minute),
    Number(out.second)
  );
  return asUtc - ms;
}

function slotsToUtc(tz, year, month, day, hour, minute) {
  const wall = Date.UTC(year, month - 1, day, hour, minute);
  let guess = wall;
  for (let i = 0; i < 3; i += 1) {
    const next = wall - slotsOffsetMs(tz, guess);
    if (next === guess) break;
    guess = next;
  }
  return guess;
}

function slotsParts(tz, ms) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    weekday: 'short'
  });
  const out = {};
  for (const part of fmt.formatToParts(new Date(ms))) {
    if (part.type !== 'literal') out[part.type] = part.value;
  }
  return out;
}

function slotsLabel(tz, ms) {
  const p = slotsParts(tz, ms);
  return p.year + '-' + p.month + '-' + p.day + ' ' + p.hour + ':' + p.minute + ' ' + tz;
}

export async function slots(input, io) {
  const host = await io.fetch('Host', String(input.hostId || ''));
  if (!host) return { error: 'NotFound' };

  const date = String(input.date || '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return { error: 'Invalid' };
  const tz = String(input.tz || host.timezone);
  const dur = Number(input.dur || 30);
  if (!Number.isInteger(dur) || dur < 15 || dur > 240 || dur % 15 !== 0) {
    return { error: 'Invalid' };
  }

  const [year, month, day] = date.split('-').map(Number);
  const dayStart = slotsToUtc(tz, year, month, day, 0, 0);
  const dayEnd = dayStart + 24 * 3600 * 1000;
  const now = Date.now();

  const holds = await io.find('Hold', { where: { hostId: host.id }, limit: 5000 });
  const busyCells = new Set((holds.items || []).map((row) => Date.parse(String(row.cell))));

  const [wsH, wsM] = String(host.workStart).split(':').map(Number);
  const [weH, weM] = String(host.workEnd).split(':').map(Number);
  const workStartMin = wsH * 60 + wsM;
  const workEndMin = weH * 60 + weM;

  const step = 15 * 60 * 1000;
  const length = dur * 60 * 1000;
  const out = [];

  for (let t = dayStart; t + length <= dayEnd; t += step) {
    if (t < now + 5 * 60 * 1000) continue;

    const startParts = slotsParts(host.timezone, t);
    const endParts = slotsParts(host.timezone, t + length);
    if (startParts.weekday === 'Sat' || startParts.weekday === 'Sun') continue;
    if (startParts.weekday !== endParts.weekday) continue;
    if (startParts.day !== endParts.day) continue;

    const startMin = Number(startParts.hour) * 60 + Number(startParts.minute);
    if (startMin < workStartMin) continue;
    if (startMin + dur > workEndMin) continue;

    let free = true;
    for (let cell = t; cell < t + length; cell += step) {
      if (busyCells.has(cell)) {
        free = false;
        break;
      }
    }
    if (!free) continue;

    out.push({
      startsAt: new Date(t).toISOString(),
      endsAt: new Date(t + length).toISOString(),
      hostLocal: slotsLabel(host.timezone, t),
      guestLocal: slotsLabel(tz, t)
    });
    if (out.length >= 64) break;
  }

  return { result: out };
}
