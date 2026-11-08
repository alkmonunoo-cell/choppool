// Final step: Arrived -> codes handed over -> "Handed over" everywhere; customer sees Collected
const { chromium, devices } = require('playwright');
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['iPhone 14'] });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  await p.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); ['cp_intro_done','cp_intro_kitchen','cp_intro_rider','cp_intro_host'].forEach(k => localStorage.setItem(k, 'true')); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  const ok = (c, m) => console.log(c ? 'ok' : 'FAIL', m);
  await p.goto('http://localhost:8765/index.html'); await p.waitForTimeout(1500);
  const info = await p.evaluate(async () => {
    const d = opsDate(); S.date = d;
    await api.kitchenOpenDay('demok1', d).catch(() => {});
    const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0240000001', ref: '51234567890' });
    const m = local.get('cp_orders') || []; m.push({ id: r.id, order_date: r.order_date }); local.set('cp_orders', m);
    await api.updateOrder(r.id, { status: 'paid' });
    return { id: r.id, date: r.order_date, today: d };
  });
  console.log('  order', info);
  // walk every pool of k1 on that date to delivered and collect every code
  const res = await p.evaluate(async (date) => {
    const K = await api.kitchenView('demok1', date);
    for (const pl of K.pools) for (const st of ['accepted', 'ready', 'picked_up', 'delivered']) { try { await api.updatePool(pl.id, { status: st }); } catch (e) {} }
    const K2 = await api.kitchenView('demok1', date);
    return K2.pools.map(x => x.status + ':' + x.orders.length);
  }, info.date);
  console.log('  pools', res);
  await p.evaluate(() => { location.hash = '#kitchen-demok1'; }); await p.waitForTimeout(1200);
  if (info.date !== info.today && await p.locator('[data-kday]').count()) { await p.locator(`[data-kday="${info.date}"]`).click(); await p.waitForTimeout(600); }
  ok(/received · \d+ waiting|meals received/.test(await p.locator('#view').innerText()), 'seller shows handover count after Arrived');
  // collect all codes for that date
  await p.evaluate(async (date) => { const K = await api.kitchenView('demok1', date); for (const pl of K.pools) for (const o of pl.orders) { if (!o.collected) { try { await api.collectCode('demoh1', o.code, date, null, 'cash'); } catch (e) {} try { await api.collectCode('demok1', o.code, date, null, 'cash'); } catch (e) {} } } }, info.date);
  await p.evaluate(() => { location.hash = '#order'; }); await p.waitForTimeout(300);
  await p.evaluate(() => { location.hash = '#kitchen-demok1'; }); await p.waitForTimeout(1200);
  if (info.date !== info.today && await p.locator('[data-kday]').count()) { await p.locator(`[data-kday="${info.date}"]`).click(); await p.waitForTimeout(600); }
  const t = await p.locator('#view').innerText();
  ok(/\bDone\b/.test(t), 'seller step reaches Done');
  ok(/All .* received\. This delivery is done/.test(t), 'seller sees delivery done');
  console.log('  next:', await p.locator('.nextup').innerText().catch(() => '-'));
  // customer
  await p.evaluate(() => { location.hash = '#order'; }); await p.waitForTimeout(1200); await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(800);
  const ot = await p.locator('#tabOrders').innerText(); ok(/Delivered/.test(ot) && /Got my food/.test(ot), 'customer sees Delivered + Got my food');
  await p.locator('[data-gotit]').first().click(); await p.waitForTimeout(1000);
  ok(/How was lunch/.test(await p.locator('#sheet').innerText()), 'review opens after Got my food');
  await p.evaluate(() => closeSheet()); await p.waitForTimeout(400); await p.click('[data-oseg=past]').catch(() => {}); await p.waitForTimeout(300);
  await p.screenshot({ path: '/tmp/shots/final-customer.png' });
  console.log('errors', errs); await b.close(); })();
