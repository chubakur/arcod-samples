// The dead letter is per topic; the operational view is the union. An entry
// carries {payload, attempts, lastError} as the runtime recorded it.
export async function dead(_input, io) {
  const topics = ['allocate', 'pick', 'ship', 'restock'];
  const rows = [];
  for (const topic of topics) {
    const items = (await io.queueDead(topic)) || [];
    for (const item of items) rows.push({ topic, entry: item });
  }
  return { result: rows };
}
