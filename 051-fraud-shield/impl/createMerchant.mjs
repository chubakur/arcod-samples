// A merchant is the account the fraud rules protect. dailyLimit is in minor
// units of the merchant currency; 0 means "no daily cap".
export async function createMerchant(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const name = String(body.name || '').trim();
  const dailyLimit = Number(body.dailyLimit == null ? 100000 : body.dailyLimit);
  if (!name) return { error: 'Invalid' };
  if (!Number.isInteger(dailyLimit) || dailyLimit < 0) return { error: 'Invalid' };

  const merchant = {
    id: await io.new(),
    name,
    dailyLimit,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Merchant', merchant);
  return { result: merchant };
}
