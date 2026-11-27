// Consumer 3: JSONL transcript into S3, then flip the row to ready. The object
// is written before the row is updated: a crash leaves an unreferenced object,
// never a ready row with a missing key.
export async function exportRun(input, io) {
  const exportId = typeof input === 'string' ? input : String((input && input.exportId) || '');
  if (!exportId) return { result: false };
  const row = await io.fetch('Export', exportId);
  if (!row) return { result: false };
  if (row.status === 'ready' && row.key) return { result: true };

  const tickets = await io.find('Ticket', {
    where: { tenantId: row.tenantId },
    order: 'createdAt asc',
    limit: 1000,
  });
  const lines = [];
  let messages = 0;
  for (const ticket of tickets.items || []) {
    const page = await io.find('Message', {
      where: { ticketId: ticket.id },
      order: 'createdAt asc',
      limit: 1000,
    });
    const thread = page.items || [];
    messages += thread.length;
    lines.push(JSON.stringify({ ticket, messages: thread }));
  }
  const body = lines.length ? lines.join('\n') + '\n' : '';
  const key = 'exports/' + row.tenantId + '/' + row.id + '.jsonl';
  await io.blobPut(key, body, 'application/x-ndjson');

  await io.update('Export', exportId, {
    status: 'ready',
    key,
    tickets: (tickets.items || []).length,
    messages,
    bytes: new TextEncoder().encode(body).length,
  });
  return { result: true };
}
