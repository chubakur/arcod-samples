export async function agents(_input, io) {
  const page = await io.find('Agent', { order: 'createdAt desc', limit: 100 });
  return { result: page.items || [] };
}
