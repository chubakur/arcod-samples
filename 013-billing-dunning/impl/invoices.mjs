export async function invoices(input, io) {
  const id = String(input.id || '');
  if (!id) return { result: [] };
  const found = await io.find('Invoice', { where: { subscriptionId: id }, limit: 100 });
  return { result: found.items || [] };
}
