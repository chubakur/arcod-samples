export async function stats(input, io) {
  const items = await io.count('Item', {});
  const events = await io.count('Interaction', {});
  const touches = await io.count('Touch', {});
  const pointer = await io.load('feed:pointer');
  const version = (pointer && pointer.b && Number(pointer.b.version)) || 0;
  return { result: { items, events, touches, modelVersion: version } };
}
