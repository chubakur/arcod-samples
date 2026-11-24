// Read the sealed artefact back. intact says the JSON in S3 is the one the
// sealer hashed; verified says every signature still matches the document that
// is stored today. The two are separate on purpose.
async function manifestDigest(value) {
  const bytes = new TextEncoder().encode(String(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function manifest(input, io) {
  const id = String(input.id || '');
  const envelope = await io.fetch('Envelope', id);
  if (!envelope) return { error: 'NotFound' };
  if (envelope.status !== 'completed' || !envelope.manifestHash) return { error: 'Conflict' };

  const raw = await io.blobGet(id + '/manifest.json');
  if (raw == null) return { error: 'Conflict' };
  const body = String(raw);

  const intact = (await manifestDigest(body)) === envelope.manifestHash;
  let sealed = null;
  try {
    sealed = JSON.parse(body);
  } catch {
    return { error: 'Conflict' };
  }

  const doc = await io.blobGet(envelope.documentKey);
  const text = doc == null ? null : String(doc);

  let verified = intact && text != null;
  const signers = [];
  for (const s of sealed.signers || []) {
    let ok = false;
    if (text != null && s.signature) {
      ok = (await manifestDigest(text + '|' + s.email + '|' + s.signedAt)) === s.signature;
    }
    if (!ok) verified = false;
    signers.push({
      name: s.name,
      email: s.email,
      orderIndex: s.orderIndex,
      signedAt: s.signedAt || null,
      signature: s.signature || null,
      verified: ok,
    });
  }

  return {
    result: {
      envelopeId: id,
      title: sealed.title,
      documentSize: sealed.documentSize,
      sealedAt: sealed.sealedAt,
      signers,
      verified,
      intact,
    },
  };
}
