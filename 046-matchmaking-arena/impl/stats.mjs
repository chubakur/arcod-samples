export async function stats(input, io) {
  const players = await io.count('ArenaPlayer', {});
  const waiting = await io.count('QueueTicket', { where: { status: 'waiting' } });
  const ready = await io.count('ArenaMatch', { where: { status: 'ready' } });
  const live = await io.count('ArenaMatch', { where: { status: 'live' } });
  const finished = await io.count('ArenaMatch', { where: { status: 'finished' } });
  const all = await io.find('ArenaMatch', { where: { status: 'finished' }, limit: 1000 });
  const archived = (all.items || []).filter((m) => Boolean(m.archiveKey)).length;
  return { result: { players, waiting, ready, live, finished, archived } };
}
