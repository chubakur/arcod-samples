export async function rules(_input, io) {
  const page = await io.find('Rule', { order: 'createdAt asc', limit: 200 });
  return { result: page.items || [] };
}
