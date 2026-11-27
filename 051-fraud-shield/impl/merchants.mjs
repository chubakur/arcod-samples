export async function merchants(_input, io) {
  const page = await io.find('Merchant', { order: 'createdAt asc', limit: 200 });
  return { result: page.items || [] };
}
