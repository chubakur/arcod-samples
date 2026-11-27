// Consumer 2: fan-out. One row per (item, user, status); the deterministic id
// makes a redelivered job an insert conflict that is swallowed.
export async function notify(input, io) {
  const itemId = typeof input === 'string' ? input : String((input && input.itemId) || '');
  if (!itemId) return { result: false };
  const row = await io.fetch('Item', itemId);
  if (!row) return { result: false };
  if (row.status === 'screening') return { result: true };

  const page = await io.find('Reviewer', { limit: 500 });
  const staff = page.items || [];
  const targets = [];

  if (row.status === 'pending') {
    targets.push(row.author);
    for (const person of staff) targets.push(person.userId);
  } else if (row.status === 'appealed') {
    for (const person of staff) {
      if (person.role === 'senior' || person.role === 'admin') targets.push(person.userId);
    }
  } else {
    targets.push(row.author);
  }

  const now = new Date().toISOString();
  const seen = {};
  for (const userId of targets) {
    if (!userId || seen[userId]) continue;
    seen[userId] = true;
    const id = 'ev:' + itemId + ':' + userId + ':' + row.status;
    const text = ntText(row, userId);
    try {
      await io.insert('Notification', {
        id,
        userId,
        itemId,
        kind: row.status,
        text,
        readAt: null,
        createdAt: now,
      });
    } catch (error) {
      if (!ntConflict(error)) throw error;
    }
  }
  return { result: true };
}

function ntText(row, userId) {
  if (row.status === 'pending') {
    if (row.author === userId) return 'Your content is queued for review (risk ' + row.risk + ')';
    return 'Review needed: item ' + row.id + ' risk ' + row.risk;
  }
  if (row.status === 'approved') {
    return row.author === userId ? 'Your content was approved' : 'Item approved: ' + row.id;
  }
  if (row.status === 'rejected') {
    return row.author === userId ? 'Your content was rejected: ' + row.reason : 'Item rejected: ' + row.id;
  }
  if (row.status === 'appealed') {
    return row.author === userId ? 'Your appeal is open' : 'Appeal filed for item ' + row.id;
  }
  return 'Item ' + row.id + ' is ' + row.status;
}

function ntConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
