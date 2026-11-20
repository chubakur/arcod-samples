// A plan is the price book entry: billing reads it when an invoice is born.
export async function addPlan(input, io) {
  const code = String(input.code || '').trim().toLowerCase();
  const name = String(input.name || '').trim();
  const priceCents = Number(input.priceCents);
  const intervalDays = Number(input.intervalDays == null ? 30 : input.intervalDays);

  if (!code || !name) return { error: 'Invalid' };
  if (!Number.isFinite(priceCents) || priceCents <= 0) return { error: 'Invalid' };
  if (!Number.isFinite(intervalDays) || intervalDays < 1) return { error: 'Invalid' };

  const found = await io.find('Plan', { where: { code }, limit: 1 });
  if ((found.items || []).length > 0) return { error: 'Conflict' };

  const plan = {
    id: await io.new(),
    code,
    name,
    priceCents: Math.round(priceCents),
    intervalDays: Math.round(intervalDays),
    active: true,
  };
  await io.insert('Plan', plan);
  return { result: plan };
}
