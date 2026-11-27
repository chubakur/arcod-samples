function remindStamp(iso) {
  const d = new Date(iso);
  const p = (n) => String(n).padStart(2, '0');
  return (
    d.getUTCFullYear() +
    p(d.getUTCMonth() + 1) +
    p(d.getUTCDate()) +
    'T' +
    p(d.getUTCHours()) +
    p(d.getUTCMinutes()) +
    p(d.getUTCSeconds()) +
    'Z'
  );
}

function remindIcs(booking, host) {
  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//arcod//meeting-scheduler//EN',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'UID:' + booking.id + '@arcod.local',
    'DTSTAMP:' + remindStamp(new Date().toISOString()),
    'DTSTART:' + remindStamp(booking.startsAt),
    'DTEND:' + remindStamp(booking.endsAt),
    'SUMMARY:Reminder: meeting with ' + host.name,
    'ORGANIZER;CN=' + host.name + ':mailto:' + host.email,
    'ATTENDEE;CN=' + booking.guestEmail + ':mailto:' + booking.guestEmail,
    'DESCRIPTION:Starts ' + booking.guestLocal + ' (guest) / ' + booking.hostLocal + ' (host)',
    'BEGIN:VALARM',
    'TRIGGER:-PT15M',
    'ACTION:DISPLAY',
    'DESCRIPTION:Meeting with ' + host.name,
    'END:VALARM',
    'END:VEVENT',
    'END:VCALENDAR',
    ''
  ].join('\r\n');
}

export async function remind(input, io) {
  const reminderId = String((input && input.reminderId) || '');
  if (!reminderId) return { reminded: false };

  const reminder = await io.fetch('Reminder', reminderId);
  if (!reminder || reminder.status === 'sent') return { reminded: false };

  const booking = await io.fetch('Booking', reminder.bookingId);
  if (!booking || booking.status !== 'confirmed') {
    await io.update('Reminder', reminder.id, { status: 'skipped' });
    return { reminded: false, skipped: true };
  }
  const host = await io.fetch('Host', booking.hostId);
  if (!host) return { reminded: false };

  const key = 'reminders/' + booking.id + '.ics';
  await io.blobPut(key, remindIcs(booking, host), 'text/calendar; charset=utf-8');
  await io.update('Reminder', reminder.id, { status: 'sent' });
  return { reminded: true, key };
}
