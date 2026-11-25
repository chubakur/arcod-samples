export async function stats(input, io) {
  const features = await io.count('Feature', { where: {} });
  const events = await io.count('Event', { where: {} });
  const pending = await io.count('Event', { where: { materialized: false } });
  const exports = await io.count('Export', { where: {} });
  const done = await io.count('Export', { where: { status: 'done' } });
  return { result: { features, events, pending, exports, done } };
}
