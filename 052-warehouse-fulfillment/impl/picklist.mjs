export async function picklist(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const orderId = String(body.orderId || '');
  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { error: 'NotFound' };
  const page = await io.find('PickList', { where: { orderId }, limit: 1 });
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound' };
  const text = await io.blobGet(row.key);
  const content = text == null ? '' : String(text);
  return { result: { key: row.key, content, bytes: content.length } };
}
