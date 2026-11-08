// Release C: tab re-tap, name privacy, legal pages, notif dimming, theme icon, admin settings + cards, seller simple mode
const { chromium, devices } = require('playwright');
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['iPhone 14'] });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  await p.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  const ok = (c, m) => console.log(c ? 'ok' : 'FAIL', m);
  await p.goto('http://localhost:8765/index.html'); await p.waitForTimeout(1500);
  // tab re-tap: vendors search clears
  await p.click('.tabbar [data-tab=kitchens]'); await p.fill('#vq', 'jollof'); await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300);
  ok((await p.inputValue('#vq')) === '', 're-tap Vendors clears search');
  await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(500); ok(await p.locator('#vpage').count() === 1, 'vendor page open');
  await p.evaluate(() => document.querySelector('.tabbar [data-tab=kitchens]').click()); await p.waitForTimeout(400); ok(await p.locator('#vpage').count() === 0, 're-tap closes vendor page');
  // orders re-tap -> upcoming
  await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(300); const past = p.locator('[data-oseg=past]'); if (await past.count()) { await past.click(); await p.waitForTimeout(200); }
  await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(300); ok(await p.evaluate(() => S.oseg) === 'up', 're-tap Orders goes to Upcoming');
  // place an order, then hide name and rate
  const id = await p.evaluate(async () => { await api.kitchenOpenDay('demok1', S.date).catch(()=>{}); const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0240000001', ref: '51234567890' }); const m = local.get('cp_orders') || []; m.push({ id: r.id, order_date: r.order_date }); local.set('cp_orders', m); return r.id; });
  await p.click('.tabbar [data-tab=wallet]'); await p.waitForTimeout(400); await p.click('#profBtn'); await p.waitForTimeout(300);
  await p.fill('#pfName', 'Ama Owusu'); await p.uncheck('#pfShow', { force: true }); await p.click('#pfForm button.btn'); await p.waitForTimeout(400); console.log('  hide flag', await p.evaluate(() => localStorage.getItem('cp_hide_name')));
  const hidden = await p.evaluate(async id => { await api.updateOrder(id, { status: 'paid' }); return (await api.myOrders([id])).length && true; }, id);
  const rv = await p.evaluate(async id => { await api.collectCode('demoh1', (await api.myOrders([id]))[0].code, S.date, null, 'cash').catch(() => {}); await api.confirmReceived?.(id).catch?.(() => {}); try { await api.submitReview(id, '0240000001', 5, 'Lovely'); } catch (e) { return 'rate err ' + e.message; } const rs = await api.kitchenReviews('k1'); return rs.find(r => r.comment === 'Lovely'); }, id);
  ok(rv && typeof rv === 'object' && !rv.name, 'review name hidden (' + JSON.stringify(rv && rv.name) + ')');
  await p.evaluate(() => closeSheet());
  // account legal row
  await p.click('[data-acc=legal]'); await p.waitForTimeout(300); ok(/Data Protection Act/.test(await p.locator('#sheet').innerText()), 'privacy sheet');
  await p.click('[data-lt=terms]'); ok(/Cancellations and refunds/.test(await p.locator('#sheet').innerText()), 'terms tab'); await p.evaluate(() => closeSheet());
  // notifications dimmed when alerts off
  await p.evaluate(() => localStorage.setItem('cp_alerts', 'false')); await p.click('[data-acc=notif]'); await p.waitForTimeout(300);
  ok(await p.locator('#nsBody .glist.dim').count() > 0, 'alert types dimmed when alerts off'); await p.evaluate(() => closeSheet());
  // theme icon is moon/sun
  const th = await p.evaluate(() => themeBtn()); ok(/M21 12.8|circle cx="12" cy="12" r="4"/.test(th), 'theme button is moon or sun');
  // legal page route
  await p.goto('http://localhost:8765/index.html#terms'); await p.waitForTimeout(1200); ok(/Terms of use/.test(await p.locator('#view h1').innerText()), 'terms page');
  // admin settings one save + cards
  await p.goto('http://localhost:8765/index.html#admin'); await p.waitForTimeout(1500);
  await p.click('[data-atab=settings]'); await p.waitForTimeout(400); ok(await p.locator('[data-form=settings] button.btn').count() === 1, 'settings has one Save');
  await p.fill('#pfBase', '22'); await p.fill('#rlNear', '45'); await p.click('[data-form=settings] button.btn'); await p.waitForTimeout(600);
  ok(await p.evaluate(() => S.settings.base_fare == 22 && S.settings.near_max_fee == 45), 'settings saved together');
  await p.click('[data-atab=today]'); await p.waitForTimeout(300); await p.click('#aSub [data-asub=orders]'); await p.waitForTimeout(500); if (await p.locator('[data-aday]').count() > 1) { await p.locator('[data-aday]').nth(1).click(); await p.waitForTimeout(600); }
  await p.screenshot({ path: '/tmp/shots/a-orders-cards.png', fullPage: true });
  ok(await p.locator('table.cardtable td[data-label]').count() > 0, 'orders render as labelled cards');
  ok(await p.evaluate(() => getComputedStyle(document.querySelector('table.cardtable tr[data-orow]')).display) === 'grid', 'order rows are cards on phone');
  // seller simple mode
  await p.goto('http://localhost:8765/index.html#kitchen-demok1'); await p.waitForTimeout(1500);
  ok(await p.locator('.settingsfold').count() === 1, 'seller settings folded');
  ok(await p.locator('[data-kday]').count() === 0 || await p.locator('.chips [data-kday]').count() > 0, 'seller day chips');
  console.log('errors', errs); await b.close(); })();
