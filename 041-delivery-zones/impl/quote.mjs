function pointInPolygon(lat, lng, points) {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const xi = Number(points[i][0]);
    const yi = Number(points[i][1]);
    const xj = Number(points[j][0]);
    const yj = Number(points[j][1]);
    const crosses = yi > lat !== yj > lat;
    if (crosses && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

function polygonArea(points) {
  let sum = 0;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    sum += Number(points[j][0]) * Number(points[i][1]) - Number(points[i][0]) * Number(points[j][1]);
  }
  return Math.abs(sum / 2);
}

export async function quote(input, io) {
  const lat = Number(input.lat);
  const lng = Number(input.lng);
  const distanceKm = Number(input.distanceKm);

  if (!Number.isFinite(lat) || lat < -90 || lat > 90) return { error: 'Invalid' };
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) return { error: 'Invalid' };
  if (!Number.isFinite(distanceKm) || distanceKm < 0 || distanceKm > 1000) return { error: 'Invalid' };

  const cacheKey = 'zone:' + lat.toFixed(3) + ':' + lng.toFixed(3);
  let cachedZone = false;
  let zone = null;

  const hit = await io.load(cacheKey);
  const zoneId = hit && hit.b ? hit.b.zoneId : null;
  if (zoneId) {
    try {
      zone = await io.fetch('Zone', String(zoneId));
      cachedZone = Boolean(zone && zone.active);
    } catch {
      zone = null;
    }
  }

  if (!zone) {
    const found = await io.find('Zone', { where: { active: true }, limit: 200 });
    let best = null;
    let bestArea = Infinity;
    for (const candidate of found.items || []) {
      let points;
      try {
        points = JSON.parse(candidate.polygon);
      } catch {
        continue;
      }
      if (!Array.isArray(points) || points.length < 3) continue;
      if (!pointInPolygon(lat, lng, points)) continue;
      const area = polygonArea(points);
      if (area < bestArea) {
        best = candidate;
        bestArea = area;
      }
    }
    zone = best;
  }

  if (!zone) return { error: 'NotFound' };

  const geoKey = 'geo:' + lat.toFixed(4) + ':' + lng.toFixed(4);
  let address = null;
  const geoHit = await io.load(geoKey);
  if (geoHit && geoHit.b && geoHit.b.label) address = String(geoHit.b.label);

  if (!address) {
    try {
      const out = await io.remote('Geocoder', 'reverse', { lat, lng });
      const body = out && out.body !== undefined ? out.body : out;
      if (body && body.label) address = String(body.label);
    } catch {
      address = 'unknown';
    }
    if (address && address !== 'unknown') {
      await io.save(geoKey, { b: { label: address }, h: null });
    }
  }

  const price = Number(zone.basePrice) + Math.round(distanceKm * Number(zone.perKm));
  const id = await io.new();
  const quoteRow = {
    id,
    zoneId: String(zone.id),
    lat,
    lng,
    distanceKm,
    price,
    address: address || 'unknown',
    cachedZone,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Quote', quoteRow);

  // Cache the winning zone for this rounded coordinate. A later quote within
  // the same 0.001-degree cell skips the polygon scan.
  await io.save(cacheKey, { b: { zoneId: String(zone.id) }, h: null });

  return { result: quoteRow };
}
