// Consumer 2. The snapshot is immutable and keyed by match id; a redelivery
// sees archiveKey and returns, so S3 gets exactly one object per match.
export async function archive(input, io) {
  const id = String(input.matchId || input || '');
  const match = await io.fetch('ArenaMatch', id);
  if (!match) return { result: { skipped: true } };
  if (match.archiveKey) return { result: { key: match.archiveKey, duplicate: true } };

  const members = (await io.find('ArenaMember', { where: { matchId: id } })).items || [];
  const team = (side) =>
    members
      .filter((m) => m.team === side)
      .map((m) => ({
        playerId: m.playerId,
        name: m.name,
        ratingBefore: m.ratingBefore,
        ratingAfter: m.ratingAfter,
        delta: m.delta
      }));
  const content = JSON.stringify(
    {
      matchId: id,
      winner: match.winner,
      status: match.status,
      finishedAt: match.finishedAt,
      teams: { A: team('A'), B: team('B') }
    },
    null,
    2
  );
  const key = 'matches/' + id + '.json';
  await io.blobPut(key, content, 'application/json');
  await io.update('ArenaMatch', id, { archiveKey: key });
  return { result: { key } };
}
