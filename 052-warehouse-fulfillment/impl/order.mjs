export async function order(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const id = String(body.orderId || '');
  const row = await io.fetch('SalesOrder', id);
  if (!row) return { error: 'NotFound' };
  const lines = await io.find('OrderLine', { where: { orderId: id }, order: 'sku asc', limit: 100 });
  const reservations = await io.find('Reservation', { where: { orderId: id }, order: 'createdAt asc', limit: 200 });
  const picks = await io.find('PickList', { where: { orderId: id }, limit: 1 });
  const shipments = await io.find('Shipment', { where: { orderId: id }, limit: 5 });
  return {
    result: {
      order: row,
      lines: lines.items || [],
      reservations: reservations.items || [],
      pickList: picks.items || [],
      shipments: shipments.items || [],
    },
  };
}
