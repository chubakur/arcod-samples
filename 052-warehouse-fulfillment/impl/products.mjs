export async function products(_input, io) {
  const page = await io.find('Product', { order: 'sku asc', limit: 200 });
  return { result: page.items || [] };
}
