export async function subscription(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const sub = await io.fetch('Subscription', id);
  if (!sub) return { error: 'NotFound' };
  return { result: sub };
}
