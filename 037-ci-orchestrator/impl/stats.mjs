export async function stats(input, io) {
  const count = async (status) => Number(await io.count('Run', { where: { status } }));
  const queued = await count('queued');
  const running = await count('running');
  const succeeded = await count('succeeded');
  const failed = await count('failed');
  const cancelled = await count('cancelled');
  const artifacts = Number(await io.count('Artifact', { where: {} }));
  return {
    result: {
      queued,
      running,
      succeeded,
      failed,
      cancelled,
      total: queued + running + succeeded + failed + cancelled,
      artifacts,
    },
  };
}
