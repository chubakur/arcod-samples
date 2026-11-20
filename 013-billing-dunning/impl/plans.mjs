export async function plans(input, io) {
  const found = await io.find('Plan', { where: {}, limit: 100 });
  return { result: found.items || [] };
}
