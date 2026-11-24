export async function stats(input, io) {
  const count = async (status) => Number(await io.count('Message', { where: { status } }));
  const dead = await io.queueDead('deliver');
  return {
    result: {
      messages: Number(await io.count('Message', { where: {} })),
      delivered: await count('delivered'),
      failed: await count('failed'),
      ignored: await count('ignored'),
      retrying: Number(await io.count('Delivery', { where: { status: 'retrying' } })),
      attachments: Number(await io.count('Attachment', { where: {} })),
      dead: (dead || []).length,
    },
  };
}
