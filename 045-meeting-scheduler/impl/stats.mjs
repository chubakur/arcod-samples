export async function stats(input, io) {
  const hosts = await io.count('Host');
  const bookings = await io.count('Booking');
  const cancelled = await io.count('Booking', { where: { status: 'cancelled' } });
  const invites = await io.count('Invite');
  const pendingInvites = await io.count('Invite', { where: { status: 'pending' } });
  const reminders = await io.count('Reminder');
  return {
    result: {
      hosts: hosts || 0,
      bookings: bookings || 0,
      cancelled: cancelled || 0,
      invites: invites || 0,
      pendingInvites: pendingInvites || 0,
      reminders: reminders || 0
    }
  };
}
