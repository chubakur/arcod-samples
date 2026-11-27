// Cron hook, not a sender. It claims reminders that are due and enqueues one
// message per reminder; the queue retries and dead-letters on its own. Two
// dispatchers racing may both claim the same row - the consumer is idempotent
// by reminder status, so the second delivery is a no-op.
export async function dispatch(input, io) {
  const parsed = input.now ? Date.parse(String(input.now)) : Date.now();
  const now = Number.isNaN(parsed) ? Date.now() : parsed;

  const pending = await io.find('Reminder', { where: { status: 'pending' }, limit: 200 });
  let due = 0;
  let queued = 0;

  for (const reminder of pending.items || []) {
    if (Date.parse(String(reminder.dueAt)) > now) continue;
    due += 1;
    await io.update('Reminder', reminder.id, { status: 'queued' });
    await io.queuePublish('reminder', { reminderId: reminder.id });
    queued += 1;
  }

  return { result: { due, queued } };
}
