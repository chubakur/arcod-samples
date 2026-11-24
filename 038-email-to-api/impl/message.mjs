// The body lives in object storage; the row only carries the key. A missing
// object is a NotFound, not an empty string, so a broken upload is visible.
export async function message(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Message', id);
  if (!found) return { error: 'NotFound' };

  const body = await io.blobGet(found.bodyKey);
  if (body == null) return { error: 'NotFound' };

  const found2 = await io.find('Attachment', { where: { messageId: id }, order: 'name asc', limit: 50 });
  return {
    result: {
      message: found,
      body: String(body),
      attachments: found2.items || [],
    },
  };
}
