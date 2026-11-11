const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['dark', 'light']) {
  const p = await phone(b, { time: '2026-11-09T09:45:00Z', scheme, viewport: { width: 390, height: 844 } });
  p.on('dialog', d => d.accept());
  const ids = await p.evaluate(async () => {
    const add = (site, item, q, n, ph, paid = true) => api.placeOrder({ site, item, qty: q, name: n, phone: ph, ref: paid ? '51234567' + Math.floor(Math.random() * 90 + 10) : '' });
    const a = await add('s1', 'i1', 2, 'Ama Owusu', '0244111201'); await add('s1', 'i2', 1, 'Kofi Boateng', '0244111202'); await add('s1', 'i1', 1, 'Esi Mensah', '0244111203');
    const y = await add('s2', 'i2', 3, 'Yaw Darko', '0244111204'); await add('s1', 'i2', 1, 'Late Payer', '0244111209');
    for (const o of (await api.adminData(a.order_date)).orders.filter(o => o.customer_name !== 'Late Payer')) await api.updateOrder(o.id, { status: 'paid' }); return a; });
  await p.evaluate(() => location.hash = '#kitchen-demok1'); await p.waitForTimeout(1800);
  const make = await txt(p, '.vmake');
  if (scheme === 'dark') ok(/Make (today|tomorrow)/.test(make) && /\d+\s*\n?.*Jollof/.test(make), 'v.1', 'Make card totals dishes', make.replace(/\n/g, ' | ').slice(0, 200));
  const rows = await p.locator('[data-pack]').count();
  if (scheme === 'dark') ok(rows >= 3, 'v.2', 'tick boxes for paid packs', rows);
  await p.locator('[data-pack]').first().click(); await p.waitForTimeout(400);
  if (scheme === 'dark') ok(await p.locator('[data-pack].on').count() === 1 && /1 of \d+ pack/.test(await txt(p, '#view')), 'v.3', 'ticking a pack counts it');
  await p.screenshot({ path: `/tmp/e2e/shots27/vpack-${scheme}.png`, fullPage: true });
  if (false) { // mark ready with an unticked pack: asks first
    await p.evaluate(async () => { const pool = (await api.kitchenView('demok1', S.date || today())).pools?.[0]; });
    const ready = p.locator('button[data-k="ready"]');
    if (await ready.count()) { await ready.first().click(); await p.waitForTimeout(400); ok(/not ticked/.test(await txt(p, '#sheet')), 'v.4', 'asks before Food ready with unticked packs'); }
    else { await p.locator('button[data-k="accepted"]').first().click().catch(() => {}); await p.waitForTimeout(800);
      const r2 = p.locator('button[data-k="ready"]'); if (await r2.count()) { await r2.first().click(); await p.waitForTimeout(400); ok(/not ticked/.test(await txt(p, '#sheet')), 'v.4', 'asks before Food ready with unticked packs', await txt(p, '#sheet')); } else console.log('no ready button'); }
  }
  console.log(scheme, p.errs); await p.context().close(); }
  // after the cut-off: confirm the batch, then Food ready asks about unticked packs
  { const p = await phone(b, { time: '2026-11-09T10:00:00Z', viewport: { width: 390, height: 844 } });
    await p.evaluate(async () => { const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 2, name: 'Ama Owusu', phone: '0244111201', ref: '5123456711' });
      await api.placeOrder({ site: 's1', item: 'i2', qty: 1, name: 'Kofi Boateng', phone: '0244111202', ref: '5123456712' });
      for (const o of (await api.adminData(a.order_date)).orders) await api.updateOrder(o.id, { status: 'paid' }); });
    await p.clock.fastForward('45:00');
    await p.evaluate(() => location.hash = '#kitchen-demok1'); await p.waitForTimeout(1800);
    const conf = p.locator('button[data-k="accepted"]'); if (await conf.count()) { await conf.first().click(); await p.waitForTimeout(900); }
    await p.locator('[data-pack]').first().click(); await p.waitForTimeout(400);
    await p.locator('button[data-k="ready"]').first().click(); await p.waitForTimeout(400);
    ok(/1 pack not ticked/.test(await txt(p, '#sheet')), 'v.4', 'asks before Food ready when a pack is not ticked', await txt(p, '#sheet'));
    await p.click('#rdyYes'); await p.waitForTimeout(900);
    ok(/Waiting for rider/.test(await txt(p, '#view')), 'v.5', 'Mark ready anyway still works');
    console.log('cut', p.errs); }
  await b.close(); })();
