export async function messages(input, io) {
  const total = await io.count('Message', { where: {} });
  const found = await io.find('Message', { where: {}, order: 'createdAt desc', limit: 50 });
  return { result: { items: found.items || [], total: Number(total) } };
}
