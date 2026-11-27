export async function label(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const orderId = String(body.orderId || '');
  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { error: 'NotFound' };
  const page = await io.find('Shipment', { where: { orderId }, limit: 1 });
  const row = (page.items || [])[0];
  if (!row || !row.labelKey) return { error: 'NotFound' };
  const text = await io.blobGet(row.labelKey);
  const content = text == null ? '' : String(text);
  return { result: { key: row.labelKey, content, bytes: content.length } };
}
