// One catalogue row. The title carries the unique index, so a duplicate is a
// real 409 from the store (the adapter maps the unique violation itself).
export async function addItem(input, io) {
  const title = String(input.title || '').trim();
  const category = String(input.category || '').trim();
  const price = Number(input.price);

  if (!title || title.length > 120) return { error: 'Invalid' };
  if (!category || category.length > 40) return { error: 'Invalid' };
  if (!Number.isInteger(price) || price < 0 || price > 10000000) return { error: 'Invalid' };

  const item = {
    id: await io.new(),
    title,
    category,
    price,
    active: true,
    createdAt: new Date().toISOString(),
  };
  try {
    await io.insert('Item', item);
  } catch (error) {
    if (addItemIsConflict(error)) return { error: 'Conflict' };
    throw error;
  }
  return { result: item };
}

function addItemIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
