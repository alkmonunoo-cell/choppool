const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme, viewport: { width: 390, height: 900 } });
  await p.evaluate(async () => { for (let i = 0; i < 3; i++) await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama ' + i, phone: '024411120' + i, ref: '512345671' + i });
    const a = (await api.adminData(today())).orders; for (const o of a) await api.updateOrder(o.id, { status: 'paid' }); });
  await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(1800);
  await p.evaluate(() => document.querySelector('[data-atab="today"]').click()); await p.waitForTimeout(400);
  await p.evaluate(() => document.querySelector('[data-asub="pools"]').click()); await p.waitForTimeout(900);
  const card = p.locator('[data-pool]').first();
  const tb = await card.locator('.tripbox').innerText();
  if (scheme === 'light') ok(/Customers pay GHS [\d.]+ for delivery/.test(tb), 'r.1', 'shows what customers pay for the trip', tb.replace(/\n/g, ' '));
  await card.locator('[data-f=via]').selectOption('rider'); await p.waitForTimeout(200);
  if (scheme === 'light') ok(await card.locator('[data-via-rider]').isVisible() && !(await card.locator('[data-via-app]').isVisible()), 'r.2', 'ChopPool rider shows the rider list');
  await card.screenshot({ path: `/tmp/e2e/shots27/via-${scheme}.png` });
  if (scheme === 'light') {
    await card.locator('[data-act=pool-save]').click(); await p.waitForTimeout(400);
    ok(/Pick which ChopPool rider/.test(await txt(p, '.toast')), 'r.3', 'asks for a rider before saving');
    const rid = await card.locator('[data-f=rider_id] option').nth(1).getAttribute('value');
    await card.locator('[data-f=rider_id]').selectOption(rid); await card.locator('[data-act=pool-save]').click(); await p.waitForTimeout(900);
    ok(await p.evaluate(() => S.admin.pools.some(x => x.rider_id)), 'r.4', 'rider saved');
    const c2 = p.locator('[data-pool]').first();
    await c2.locator('[data-f=via]').selectOption('Yango'); await p.waitForTimeout(200);
    ok(await c2.locator('[data-via-app]').isVisible() && !(await c2.locator('[data-via-rider]').isVisible()), 'r.5', 'Yango shows the booking code');
    await c2.locator('[data-f=trip_ref]').fill('YG-4471'); await c2.locator('[data-f=trip_cost]').fill('35'); await c2.locator('[data-act=pool-save]').click(); await p.waitForTimeout(900);
    const pl = await p.evaluate(() => S.admin.pools.find(x => x.trip_ref));
    ok(pl && pl.trip_ref === 'Yango · YG-4471' && !pl.rider_id && Number(pl.trip_cost) === 35, 'r.6', 'Yango booking saved with code and cost', JSON.stringify(pl && [pl.trip_ref, pl.rider_id, pl.trip_cost]));
    ok(await p.locator('[data-pool]').first().locator('[data-f=via]').inputValue() === 'Yango' && await p.locator('[data-pool]').first().locator('[data-f=trip_ref]').inputValue() === 'YG-4471', 'r.7', 'reopens as Yango with its code');
  }
  console.log(scheme, p.errs); await p.context().close(); }
  await b.close(); })();
