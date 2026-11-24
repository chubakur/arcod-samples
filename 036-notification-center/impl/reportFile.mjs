export async function reportFile(input, io) {
  const id = String(input.id || '');
  const campaign = await io.fetch('Campaign', id);
  if (!campaign) return { error: 'NotFound' };
  const key = 'reports/' + id + '.csv';
  const body = await io.blobGet(key);
  if (body == null) return { error: 'NotFound' };
  return { result: { name: 'campaign-' + id + '.csv', type: 'text/csv', body: String(body) } };
}
