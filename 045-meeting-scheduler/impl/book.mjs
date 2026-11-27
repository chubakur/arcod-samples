function bookOffsetMs(tz, ms) {
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
  return (
    Date.UTC(
      Number(out.year),
      Number(out.month) - 1,
      Number(out.day),
      Number(out.hour),
      Number(out.minute),
      Number(out.second)
    ) - ms
  );
}

function bookParts(tz, ms) {
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

function bookLabel(tz, ms) {
  const p = bookParts(tz, ms);
  return p.year + '-' + p.month + '-' + p.day + ' ' + p.hour + ':' + p.minute + ' ' + tz;
}

function bookIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}

export async function book(input, io) {
  const host = await io.fetch('Host', String(input.hostId || ''));
  if (!host) return { error: 'NotFound' };

  const guestEmail = String(input.guestEmail || '').trim().toLowerCase();
  const guestTimezone = String(input.guestTimezone || host.timezone).trim();
  const startsAt = Date.parse(String(input.startsAt || ''));
  const dur = Number(input.dur || 30);

  if (!guestEmail.includes('@') || Number.isNaN(startsAt)) return { error: 'Invalid' };
  if (!Number.isInteger(dur) || dur < 15 || dur > 240 || dur % 15 !== 0) {
    return { error: 'Invalid' };
  }
  if (startsAt % (15 * 60 * 1000) !== 0) return { error: 'Invalid' };
  if (startsAt < Date.now()) return { error: 'Invalid' };

  try {
    new Intl.DateTimeFormat('en-US', { timeZone: guestTimezone }).format(new Date());
  } catch (error) {
    return { error: 'Invalid' };
  }

  const startParts = bookParts(host.timezone, startsAt);
  const endParts = bookParts(host.timezone, startsAt + dur * 60000);
  if (startParts.weekday === 'Sat' || startParts.weekday === 'Sun') return { error: 'Invalid' };
  if (startParts.day !== endParts.day) return { error: 'Invalid' };

  const [wsH, wsM] = String(host.workStart).split(':').map(Number);
  const [weH, weM] = String(host.workEnd).split(':').map(Number);
  const startMin = Number(startParts.hour) * 60 + Number(startParts.minute);
  if (startMin < wsH * 60 + wsM) return { error: 'Invalid' };
  if (startMin + dur > weH * 60 + weM) return { error: 'Invalid' };

  // Every 15-minute cell the meeting touches becomes a row with a unique key.
  // Insert is the compare-and-swap: the second racer gets Conflict, not a
  // double booking.
  const cells = [];
  for (let t = startsAt; t < startsAt + dur * 60000; t += 15 * 60 * 1000) cells.push(t);

  const bookingId = await io.new();
  const now = new Date().toISOString();
  const booking = {
    id: bookingId,
    hostId: host.id,
    hostName: host.name,
    guestEmail,
    guestTimezone,
    startsAt: new Date(startsAt).toISOString(),
    endsAt: new Date(startsAt + dur * 60000).toISOString(),
    durationMin: dur,
    status: 'confirmed',
    inviteKey: '',
    hostLocal: bookLabel(host.timezone, startsAt),
    guestLocal: bookLabel(guestTimezone, startsAt),
    createdAt: now
  };

  await io.insert('Booking', booking);

  const held = [];
  try {
    for (const cell of cells) {
      const hold = {
        id: await io.new(),
        key: host.id + ':' + new Date(cell).toISOString(),
        hostId: host.id,
        bookingId,
        cell: new Date(cell).toISOString()
      };
      await io.insert('Hold', hold);
      held.push(hold.id);
    }
  } catch (error) {
    for (const id of held) await io.remove('Hold', id).catch(() => {});
    await io.remove('Booking', bookingId).catch(() => {});
    if (bookIsConflict(error)) return { error: 'Conflict' };
    throw error;
  }

  const invite = {
    id: await io.new(),
    key: bookingId + ':invite',
    bookingId,
    kind: 'invite',
    email: guestEmail,
    status: 'pending',
    icsKey: '',
    createdAt: now
  };
  await io.insert('Invite', invite);

  await io.insert('Reminder', {
    id: await io.new(),
    bookingId,
    dueAt: new Date(startsAt - 3600 * 1000).toISOString(),
    status: 'pending'
  });

  await io.queuePublish('invite', { inviteId: invite.id });

  return { result: booking };
}
