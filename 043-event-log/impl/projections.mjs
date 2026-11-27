export async function projections(input, io) {
  const page = await io.find('Checkpoint', { order: 'updatedAt desc', limit: 50 });
  return { result: page.items || [] };
}
