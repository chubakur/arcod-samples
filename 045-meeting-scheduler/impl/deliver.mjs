// Consumer 1: compose the calendar file and put it in S3. The queue message
// carries only the invite id; everything else is re-read, so a redelivery after
// a crash is harmless (status sent is the guard).
function deliverStamp(iso) {
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

function deliverText(value) {
  return String(value || '').replace(/[\r\n]+/g, ' ');
}
function deliverIcs(invite, booking, host) {
  const cancel = invite.kind === 'cancel';
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//arcod//meeting-scheduler//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:' + (cancel ? 'CANCEL' : 'REQUEST'),
    'BEGIN:VEVENT',
    'UID:' + booking.id + '@arcod.local',
    'DTSTAMP:' + deliverStamp(new Date().toISOString()),
    'DTSTART:' + deliverStamp(booking.startsAt),
    'DTEND:' + deliverStamp(booking.endsAt),
    'SEQUENCE:' + (cancel ? '1' : '0'),
    'STATUS:' + (cancel ? 'CANCELLED' : 'CONFIRMED'),
    'SUMMARY:' + deliverText((cancel ? 'Cancelled: ' : '') + 'Meeting with ' + host.name),
    'ORGANIZER;CN=' + deliverText(host.name) + ':mailto:' + host.email,
    'ATTENDEE;CN=' + deliverText(booking.guestEmail) + ';RSVP=TRUE:mailto:' + booking.guestEmail,
    'LOCATION:Online',
    'DESCRIPTION:' + deliverText('Host time ' + booking.hostLocal + ' / guest time ' + booking.guestLocal),
    'END:VEVENT',
    'END:VCALENDAR',
    ''
  ];
  return lines.join('\r\n');
}

export async function deliver(input, io) {
  const inviteId = String((input && input.inviteId) || '');
  if (!inviteId) return { delivered: false };

  const invite = await io.fetch('Invite', inviteId);
  if (!invite) return { delivered: false };
  if (invite.status === 'sent') return { delivered: false, duplicate: true };

  const booking = await io.fetch('Booking', invite.bookingId);
  if (!booking) return { delivered: false };
  const host = await io.fetch('Host', booking.hostId);
  if (!host) return { delivered: false };

  const key = 'invites/' + booking.id + '/' + invite.kind + '.ics';
  await io.blobPut(key, deliverIcs(invite, booking, host), 'text/calendar; charset=utf-8');
  await io.update('Invite', invite.id, { status: 'sent', icsKey: key });
  if (invite.kind === 'invite') {
    await io.update('Booking', booking.id, { inviteKey: key });
  }
  return { delivered: true, key };
}
