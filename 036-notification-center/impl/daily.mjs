export async function daily(input, io) {
  const page = await io.find('DayStat', { where: {}, limit: 100 });
  const items = page.items || [];
  return {
    result: {
      items,
      sent: items.reduce((sum, item) => sum + Number(item.sent || 0), 0),
      failed: items.reduce((sum, item) => sum + Number(item.failed || 0), 0),
    },
  };
}
