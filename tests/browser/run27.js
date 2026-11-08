const { chromium, devices } = require('playwright');
const ok = (c, m) => { if (!c) { console.log('FAIL', m); process.exitCode = 1; } else console.log('ok', m); };
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['iPhone 14'] });
  await ctx.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); ['cp_intro_done','cp_intro_kitchen','cp_intro_rider','cp_intro_host'].forEach(k => localStorage.setItem(k, 'true')); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('dialog', d => d.dismiss());
  await p.route(/tile\.openstreetmap|nominatim/, r => r.abort());
  await p.goto('http://localhost:8765/index.html#order'); await p.waitForSelector('#tabHome'); await p.waitForTimeout(1200);
  // 1. Checkout: full trip
  await p.locator('.tabbar button', { hasText: 'Vendors' }).click(); await p.waitForTimeout(500);
  await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(700);
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300); await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(700);
  const sum = await p.locator('#sum').innerText(); ok(/Delivery, full trip/.test(sum) && /Shared by the pool/.test(sum), 'checkout shows the full trip');
  await p.fill('#fName', 'Ama Mensah').catch(()=>{}); await p.fill('#fPhone', '0241234567').catch(()=>{});
  await p.locator('#fRef').focus(); await p.waitForTimeout(400); await p.fill('#fRef', '51234567890');
  await p.locator('#submitBtn').click(); await p.waitForTimeout(1200);
  const mine = await p.evaluate(() => (JSON.parse(localStorage.getItem('cp_orders')) || [])[0]);
  ok(!!mine, 'order placed');
  await p.evaluate(() => { try { closeSheet(); closeVendor(); } catch (e) {} });
  // 2. Received step: collect via host link, then "Got my food"
  const o = await p.evaluate(async id => (await api.myOrders([id]))[0], mine.id);
  await p.evaluate(async o => { await api.collectCode('demoh1', o.code, o.order_date, null, 'cash'); }, o).catch(e => console.log('collect err', e.message));
  await p.locator('.tabbar button', { hasText: 'Orders' }).click(); await p.waitForTimeout(800); await p.evaluate(() => refreshMine()); await p.waitForTimeout(600);
  ok(await p.locator('[data-gotit]').count() === 1, '"Got my food" shows after collection');
  await p.locator('[data-problem]').click(); await p.waitForTimeout(400); await p.locator('#pbForm button').click(); await p.waitForTimeout(800);
  ok(/Problem reported/.test(await p.locator('#tabOrders').innerText()), 'problem reported shows on the order');
  // 3. Solo banner + switch (simulate 5 minutes to cut-off)
  await p.evaluate(async () => { const s = S.settings; const t = new Date(Date.now() + 5 * 6e4); s.cutoff = t.toISOString().slice(11, 16); });
  const r2 = await p.evaluate(async () => { const ok = S.menus.filter(m => !m.site_id || m.site_id === 's1'), k2 = ok[0], it = S.items.find(i => i.kitchen_id === k2.id); return api.placeOrder({ site: 's1', item: it.id, qty: 1, name: 'Kofi', phone: '0207654321', ref: '5999999999', addons: [], note: '', special: null, useWallet: false, join: null }); });
  const r3 = await p.evaluate(async () => { const okk = S.menus.filter(m => !m.site_id || m.site_id === 's1'); const k = okk[1]; const it = S.items.find(i => i.kitchen_id === k.id); return api.placeOrder({ site: 's1', item: it.id, qty: 1, name: 'Esi', phone: '0551112222', ref: '5888888888', addons: [], note: '', special: null, useWallet: false, join: null }); });
  await p.evaluate(id => { const m = JSON.parse(localStorage.getItem('cp_orders')) || []; m.push({ id, order_date: S.date }); localStorage.setItem('cp_orders', JSON.stringify(m)); }, r3.id);
  await p.evaluate(async () => { await refreshBoard(); await refreshMine(); renderOrders(); }); await p.waitForTimeout(500);
  const soloN = await p.locator('.solo').count(); ok(soloN >= 1, 'solo banner shows near cut-off (' + soloN + ')');
  if (await p.locator('[data-solo="switch"]').count()) {
    await p.locator('[data-solo="switch"]').first().click(); await p.waitForTimeout(500);
    ok(await p.locator('[data-swt]').count() >= 1, 'switch lists open pools');
    await p.locator('[data-swt]').first().click(); await p.waitForTimeout(500);
    if (!(await p.locator('#swPay').getAttribute('class')).includes('hidden')) await p.fill('#swRef', '5777777777');
    await p.locator('#swGo').click(); await p.waitForTimeout(900);
    ok(await p.evaluate(() => (S.mine || []).some(o => o.cancel_reason === 'Moved to another pool' || o.status === 'cancelled')), 'order moved to another pool');
  }
  await p.screenshot({ path: '/tmp/b_orders.png', fullPage: false });
  // 4. Rider steps
  await p.goto('http://localhost:8765/index.html#rider-demor1'); await p.waitForTimeout(1500);
  const rtxt = await p.locator('#view').innerText(); ok(!/5 minutes away/.test(rtxt), 'rider has no "5 minutes away" button');
  // 5. Admin pages
  await p.goto('http://localhost:8765/index.html#admin'); await p.waitForTimeout(1800);
  for (const [tab, sub] of [['today', 'wallets'], ['today', 'owed'], ['team', 'activity'], ['dash', null]]) {
    await p.evaluate(t => document.querySelector(`[data-atab="${t}"]`).click(), tab); await p.waitForTimeout(600);
    if (sub) { await p.locator(`#aSub [data-asub="${sub}"]`).click(); await p.waitForTimeout(800); }
    const t = await p.locator('#view').innerText(); ok(t.length > 50, 'admin ' + tab + (sub ? '/' + sub : '') + ' renders');
    if (sub === 'wallets') ok(/Problems reported/.test(t) && /Payments with no order/.test(t), 'refunds page has problems + unmatched');
    if (sub === 'owed') ok(/Sellers/.test(t) && /Riders/.test(t), 'money owed page');
  }
  await p.screenshot({ path: '/tmp/b_admin.png' });
  console.log('errors', errs); await b.close(); })();
