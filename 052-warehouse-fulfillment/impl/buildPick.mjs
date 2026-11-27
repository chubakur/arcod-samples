// Consumer 2: a picking document is a real object, not a projection. The row
// is written after the S3 put; a redelivery finds the row by orderId and
// leaves the document alone (the unique key is the backstop).
export async function buildPick(input, io) {
  const orderId = typeof input === 'string' ? input : String((input && input.orderId) || '');
  if (!orderId) return { result: { skipped: true } };

  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { result: { skipped: true } };
  if (order.status !== 'allocated') return { result: { skipped: true, status: order.status } };

  const prior = await io.find('PickList', { where: { orderId }, limit: 1 });
  if ((prior.items || []).length > 0) return { result: { skipped: true, key: prior.items[0].key } };

  const held = await io.find('Reservation', { where: { orderId, status: 'held' }, limit: 200 });
  const rows = [];
  let units = 0;
  for (const reservation of held.items || []) {
    const batch = await io.fetch('Batch', reservation.batchId);
    const line = await io.fetch('OrderLine', reservation.lineId);
    rows.push({
      sku: line ? line.sku : '',
      batch: batch ? batch.code : '',
      bin: batch ? batch.bin : '',
      expiresAt: batch ? batch.expiresAt : '',
      qty: Number(reservation.qty || 0),
    });
    units += Number(reservation.qty || 0);
  }

  const doc = {
    orderId,
    customer: order.customer,
    address: order.address,
    units,
    lines: rows,
    generatedAt: new Date().toISOString(),
  };
  const content = JSON.stringify(doc, null, 2);
  const key = 'picks/' + orderId + '.json';
  await io.blobPut(key, content, 'application/json');

  const row = {
    id: await io.new(),
    orderId,
    key,
    lines: rows.length,
    units,
    createdAt: new Date().toISOString(),
  };
  await io.insert('PickList', row);
  await io.update('SalesOrder', orderId, { status: 'picking', updatedAt: row.createdAt });
  await io.publish('ops', {
    type: 'order',
    event: 'picking',
    orderId,
    units,
    picklist: key,
  });
  return { result: { key, units, lines: rows.length } };
}
