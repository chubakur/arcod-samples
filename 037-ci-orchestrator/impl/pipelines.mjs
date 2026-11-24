export async function pipelines(input, io) {
  const page = await io.find('Pipeline', { order: 'createdAt desc', limit: 200 });
  return { result: (page.items || []) };
}
