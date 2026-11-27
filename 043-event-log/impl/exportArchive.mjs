// Reads the newest packed object straight from S3: the bytes returned here are
// the bytes a backup job would restore, not a re-render from SQL.
export async function exportArchive(input, io) {
  const streamId = String(input.streamId || '');
  const page = await io.find('Archive', {
    where: { streamId },
    order: 'createdAt desc',
    limit: 1,
  });
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound' };
  const content = await io.blobGet(row.key);
  return {
    result: {
      key: row.key,
      events: row.events,
      bytes: row.bytes,
      content: content == null ? '' : String(content),
    },
  };
}
