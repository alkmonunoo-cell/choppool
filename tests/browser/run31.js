// Update 23: tray checkout, payment methods, cancel Other, home tile, admin refresh/accordion, intro, motion
const { chromium, devices } = require('playwright');
(async () => { const b = await chromium.launch(); const ok = (c, m) => console.log(c ? 'ok' : 'FAIL', m); const errs = [];
  // Fresh phone: intro shows once
  { const ctx = await b.newContext({ ...devices['iPhone 14'] }); const p = await ctx.newPage(); p.on('pageerror', e => errs.push(e.message));
    await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
    await p.addInitScript(() => { localStorage.setItem('cp_splash_v', '1'); });
    await p.goto('http://localhost:8765/index.html'); await p.waitForTimeout(2500);
    ok(await p.locator('.intro').count() === 1, 'intro on first visit');
    await p.click('[data-inext]'); await p.waitForTimeout(700); await p.click('[data-inext]'); await p.waitForTimeout(700);
    const last = await p.locator('[data-inext]').innerText(); ok(/building|ordering/i.test(last), 'last card button: ' + last);
    await p.click('[data-iskip]'); await p.waitForTimeout(500); ok(await p.locator('.intro').count() === 0, 'skip closes it');
    await p.reload(); await p.waitForTimeout(2500); ok(await p.locator('.intro').count() === 0, 'not shown again');
    await p.evaluate(() => { location.hash = '#kitchen-demok1'; }); await p.waitForTimeout(1500); ok(/How this page works/.test(await p.locator('#sheet').innerText().catch(() => '')), 'seller link intro card');
    await ctx.close(); }
  const ctx = await b.newContext({ ...devices['iPhone 14'] }); const p = await ctx.newPage(); p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  await p.addInitScript(() => { localStorage.setItem('cp_splash_v', '1'); ['cp_intro_done', 'cp_intro_kitchen', 'cp_intro_rider', 'cp_intro_host'].forEach(k => localStorage.setItem(k, 'true')); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  await p.goto('http://localhost:8765/index.html'); await p.waitForTimeout(1500);
  // motion: pill + ghost
  await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(80); ok(await p.locator('#tabOrders.pane-in').count() === 1, 'new screen fades in'); await p.waitForTimeout(500);
  ok(await p.locator('.tabbar .tabpill').count() === 1, 'tab bar highlight glides');
  // tray
  await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(500); await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(800);
  ok(!(await p.locator('#vfoot.on').count()), 'no bottom bar before adding');
  const dishes = p.locator('#vpage [data-dish]:not([disabled])');
  await dishes.nth(0).click(); await p.waitForTimeout(400); await p.click('#dPlus'); await p.click('#dAdd'); await p.waitForTimeout(300);
  await dishes.nth(1).click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300);
  await dishes.nth(0).click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300);
  const bar = await p.locator('#vfoot').innerText(); ok(/4/.test(bar) && /2 dishes/.test(bar), 'tray bar: ' + bar.replace(/\n/g, ' '));
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(500);
  ok(await p.locator('#tLines .tline').count() === 2, 'same dish merged into one line');
  await p.fill('#fName', 'Ama Owusu').catch(() => {}); await p.fill('#fPhone', '0240000001').catch(() => {});
  const due = await p.locator('#dueTxt').innerText(); await p.fill('#fRef', '51234567890'); await p.click('#submitBtn'); await p.waitForTimeout(1200);
  ok(/pool/i.test(await p.locator('#sheet').innerText()), 'tray order placed (' + due + ')');
  const mine = await p.evaluate(async () => { const ids = (JSON.parse(localStorage.getItem('cp_orders')) || []).map(o => o.id); const rows = await api.myOrders(ids); return rows.map(o => [o.code, o.qty, o.item_name, o.status, !!o.parent_id]); });
  ok(mine.length === 2 && new Set(mine.map(x => x[0])).size === 1, 'one code for the tray: ' + JSON.stringify(mine));
  ok(JSON.parse(await p.evaluate(() => localStorage.getItem('cp_paymethods')) || '[]').length === 1, 'pay-from number saved');
  await p.evaluate(() => { closeSheet(); closeVendor(); }); await p.waitForTimeout(400);
  ok(/your meals/.test(await p.locator('#hero').innerText()), 'home tile shows my meals');
  await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(600);
  const card = await p.locator('#tabOrders .order-card').first().innerText(); ok(/3 ×/.test(card) && /Same code, packed together/.test(card), 'order card groups dishes');
  // admin pays the first dish -> the tray follows
  const st = await p.evaluate(async () => { const ids = (JSON.parse(localStorage.getItem('cp_orders')) || []).map(o => o.id); await api.updateOrder(ids[0], { status: 'paid' }); return (await api.myOrders(ids)).map(o => o.status); });
  ok(st.every(x => x === 'paid'), 'tray paid together: ' + st);
  // cancel with Other
  await p.evaluate(() => refreshMine()); await p.waitForTimeout(500); await p.locator('[data-cancel]').first().click(); await p.waitForTimeout(400);
  await p.check('input[name=why][value=Other]'); await p.click('#cancelForm button.btn'); await p.waitForTimeout(300);
  ok(/Tell us briefly/.test(await p.locator('#cancelErr').innerText()), 'Other needs a reason');
  await p.fill('#whyOther', 'Meeting moved'); await p.click('#cancelForm button.btn'); await p.waitForTimeout(600);
  const why = await p.evaluate(async () => { const ids = (JSON.parse(localStorage.getItem('cp_orders')) || []).map(o => o.id); return (await api.myOrders(ids)).map(o => o.cancel_reason || o.status); });
  ok(why.some(x => /Meeting moved/.test(x)), 'reason saved: ' + why[0]);
  // payment methods page
  await p.click('.tabbar [data-tab=wallet]'); await p.waitForTimeout(500); await p.click('[data-acc=payments]'); await p.waitForTimeout(400);
  await p.click('[data-pmedit=new]'); await p.waitForTimeout(300); await p.fill('#pmN', '0201234567'); await p.selectOption('#pmNet', 'Telecel'); await p.fill('#pmNick', 'Work'); await p.click('#pmForm button.btn'); await p.waitForTimeout(400);
  await p.locator('[data-pmdef]').first().click(); await p.waitForTimeout(400);
  const pms = JSON.parse(await p.evaluate(() => localStorage.getItem('cp_paymethods'))); ok(pms.length === 2 && pms.find(m => m.def).nick === 'Work', 'second number added and made default');
  ok(/•••• 4567/.test(await p.locator('#sheet').innerText()), 'numbers masked');
  await p.evaluate(() => closeSheet());
  // admin refresh + accordion
  await p.goto('http://localhost:8765/index.html#admin'); await p.waitForTimeout(1500);
  await p.click('#aRefresh'); await p.waitForTimeout(800); ok(/Updated \d\d:\d\d/.test(await p.locator('#aUpdated').innerText()), 'admin shows last update time');
  await p.evaluate(() => document.querySelector('[data-atab="menus"]').click()); await p.waitForTimeout(600);
  const items = p.locator('#aBody details.item'); const n = await items.count();
  if (n >= 2) { await items.nth(0).locator('summary').click(); await p.waitForTimeout(300); await items.nth(1).locator('summary').click(); await p.waitForTimeout(400);
    ok(await p.locator('#aBody details.item[open]').count() === 1, 'only one vendor card open'); } else ok(false, 'need 2 vendor cards');
  console.log('errors', errs); await b.close(); })();
