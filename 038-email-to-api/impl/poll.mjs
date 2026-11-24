// The cron hook stays cheap: it checks the mailbox row and hands one job to
// the queue. Everything expensive (provider call, S3, rows) happens in ingest.
export async function poll(input, io) {
  const id = String(input.id || '');
  const mailbox = await io.fetch('Mailbox', id);
  if (!mailbox) return { error: 'NotFound' };
  if (!mailbox.active) return { error: 'Conflict' };

  await io.queuePublish('ingest', { mailboxId: id });
  return { result: { queued: 1, mailboxes: 1 } };
}
