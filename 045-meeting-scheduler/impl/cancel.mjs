export async function cancel(input, io) {
  const id = String(input.id || '');
  const booking = await io.fetch('Booking', id);
  if (!booking) return { error: 'NotFound' };
  if (booking.status === 'cancelled') return { result: booking };

  const updated = await io.update('Booking', id, { status: 'cancelled' });

  // Release the slot cells before anything else: a cancelled meeting must free
  // the calendar even if the outbound invite never leaves the queue.
  const holds = await io.find('Hold', { where: { bookingId: id }, limit: 500 });
  for (const hold of holds.items || []) {
    await io.remove('Hold', hold.id);
  }

  const reminders = await io.find('Reminder', { where: { bookingId: id, status: 'pending' }, limit: 10 });
  for (const reminder of reminders.items || []) {
    await io.update('Reminder', reminder.id, { status: 'cancelled' });
  }

  const notice = {
    id: await io.new(),
    key: id + ':cancel',
    bookingId: id,
    kind: 'cancel',
    email: booking.guestEmail,
    status: 'pending',
    icsKey: '',
    createdAt: new Date().toISOString()
  };
  await io.insert('Invite', notice);
  await io.queuePublish('invite', { inviteId: notice.id });

  return { result: updated };
}
