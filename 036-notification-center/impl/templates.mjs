export async function templates(input, io) {
  const page = await io.find('Template', { where: {}, limit: 100 });
  return {
    result: {
      items: page.items || [],
      total: await io.count('Template', { where: {} }),
    },
  };
}
