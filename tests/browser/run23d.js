const { chromium } = require('playwright');
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, hasTouch: true, isMobile: true });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  await p.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); localStorage.setItem('cp_site', JSON.stringify('s1')); localStorage.setItem('cp_me', JSON.stringify({ name: 'Ama', phone: '0241234567' })); });
  await p.clock.install({ time: new Date('2026-11-05T09:30:00Z') });
  const step = async (n, f) => { try { await f(); console.log('ok', n); } catch (e) { console.log('FAIL', n, e.message.split('\n')[0]); } };
  await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  let code;
  await step('order with letter code + per-meal fee', async () => {
    await p.evaluate(() => openOrder('k1')); await p.waitForTimeout(500); await p.click('#plus', { force: true }); await p.waitForTimeout(100);
    console.log('  sum:', (await p.locator('#sum').innerText()).replace(/\n+/g, ' | '));
    await p.fill('#fRef', '5123456789'); await p.click('#submitBtn', { force: true }); await p.waitForTimeout(600); console.log('  after submit:', (await p.locator('#sheet').innerText()).slice(0, 120).replace(/\n+/g, ' | ')); await p.evaluate(() => closeSheet());
    await p.waitForTimeout(500); await p.evaluate(() => setTab('orders')); await p.waitForTimeout(500);
    console.log('  dbg', await p.evaluate(() => [S.tab, (S.mine||[]).length, document.getElementById('tabOrders').innerHTML.slice(0,200), localStorage.getItem('cp_orders')]));
    code = await p.locator('.order-card .c b').first().innerText(); console.log('  code', code); if (!/^[A-Z]-\d\d$/.test(code)) throw new Error('bad code'); });
  await step('add another plate', async () => {
    await p.locator('#tabOrders [data-addplate]').first().click({ force: true }); await p.waitForTimeout(500);
    console.log('  head:', (await p.locator('#sheet .top').first().innerText()).replace(/\n+/g, ' | '), '| sum:', (await p.locator('#sum').innerText()).replace(/\n+/g, ' | '), '| btn', await p.locator('#submitBtn').innerText());
    await p.locator('#sheet input[name=dish]').nth(1).check({ force: true }); await p.fill('#fRef', '5123456790'); await p.click('#submitBtn', { force: true }); await p.waitForTimeout(800);
    console.log('  card:', (await p.locator('.order-card').first().innerText()).replace(/\n+/g, ' | ').slice(0, 260)); await p.screenshot({ path: '/tmp/b3_orders.png' }); });
  await step('vendor labels grouped', async () => { const t = await p.evaluate(async c => { const K = await api.kitchenView('demok1', S.date); const pl = K.pools.find(x => x.orders.some(o => o.code === c)); return pl.orders.filter(o => o.code === c).map(o => o.item_name + (o.parent_id ? ' (added)' : '')).join(' + '); }, code); console.log('  ', t); });
  await step('host collects k27 form', async () => { const r = await p.evaluate(async c => { await api.kitchenOpenDay('demok1', S.date); return api.collectCode('demoh1', c.toLowerCase().replace('-', ''), S.date); }, code); console.log('  ', JSON.stringify(r)); });
  await step('join anyway while waiting', async () => {
    const r = await p.evaluate(async () => { setSite('s3', null, true); const a = await api.placeOrder({ site: 's3', item: 'i7', qty: 1, name: 'Kofi', phone: '0242222222', ref: '5123456700' }); const b = await api.placeOrder({ site: 's3', item: 'i8', qty: 1, name: 'Esi', phone: '0243333333', ref: '5123456701' }); await refreshBoard(); return [a.pool_status, b.pool_status, a.pool_id === b.pool_id, a.code, b.code]; });
    console.log('  ', JSON.stringify(r)); await p.click('.tabbar [data-tab=home]'); await p.waitForTimeout(500); console.log('  card:', (await p.locator('#pools .prow').first().innerText()).replace(/\n+/g, ' | ').slice(0, 220)); await p.screenshot({ path: '/tmp/b3_waiting.png' }); });
  await step('always cooking', async () => { await p.evaluate(() => location.hash = '#kitchen-demov1'); await p.waitForTimeout(1500); await p.locator('[data-preset=all]').check({ force: true }); await p.waitForTimeout(800);
    console.log('  chips on:', await p.locator('#autoDays [aria-pressed=true]').count(), '| open chip:', await p.locator('text=taking orders').count()); await p.screenshot({ path: '/tmp/b3_auto.png' });
    const pz = p.locator('#pauseDay'); console.log('  pause btn', await pz.count()); });
  await step('cancel + order again', async () => { await p.evaluate(() => location.hash = '#order'); await p.waitForTimeout(1500); await p.waitForTimeout(500); await p.evaluate(() => setTab('orders')); await p.waitForTimeout(400);
    await p.evaluate(async () => { setSite('s1', null, true); const r = await api.placeOrder({ site: 's1', item: 'i2', qty: 2, name: 'Ama', phone: '0241234567', ref: '5123456711' }); const m = local.get('cp_orders') || []; m.push({ id: r.id, order_date: r.order_date }); local.set('cp_orders', m); await refreshMine(); setTab('orders'); });
    await p.screenshot({path:'/tmp/dbg23.png'}); console.log('DBG', await p.evaluate(() => [S.tab, !!document.getElementById('vpage'), document.getElementById('sheetBg').className, document.querySelectorAll('[data-cancel]').length]));const n0 = await p.locator('.order-card').count(); await p.locator('[data-cancel]').first().click(); await p.waitForTimeout(400); await p.locator('#cancelForm button.btn').click(); await p.waitForTimeout(800); await p.click('[data-oseg=past]'); await p.waitForTimeout(300);
    console.log('  again buttons:', await p.locator('[data-again]').count(), 'cards', n0); await p.locator('[data-again]').first().click(); await p.waitForTimeout(500); console.log('  qty preset', await p.locator('#q').innerText()); });
  console.log('errors', JSON.stringify(errs)); await b.close(); })();
