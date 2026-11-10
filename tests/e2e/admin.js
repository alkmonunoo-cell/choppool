// Team screens: every tab, the main forms, owner vs coordinator, plus rider sign-up and the vendor's own menu
const { chromium, results, setArea, ok, note, phone, txt, hideToast } = require('./h');
const go = async (p, h, w = 1300) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
const view = p => txt(p, '#view');
const tab = async (p, t, s) => { await p.evaluate(t => document.querySelector(`[data-atab="${t}"]`)?.click(), t); await p.waitForTimeout(600); if (s) { await p.evaluate(s => document.querySelector(`[data-asub="${s}"]`)?.click(), s); await p.waitForTimeout(600); } };
const overflow = p => p.evaluate(() => { const W = document.documentElement.clientWidth; const bad = []; document.querySelectorAll('#view *').forEach(e => { const r = e.getBoundingClientRect(); const sc = (() => { let a = e.parentElement; while (a && a.id !== 'view') { if (/auto|scroll|hidden/.test(getComputedStyle(a).overflowX)) return true; a = a.parentElement; } return false; })(); if (r.width && r.right > W + 1 && !sc && getComputedStyle(e).position !== 'fixed') bad.push((e.id ? '#' + e.id : e.className || e.tagName).toString().slice(0, 40) + ':' + Math.round(r.right)); }); return [document.documentElement.scrollWidth > W ? 'PAGE ' + document.documentElement.scrollWidth : '', ...bad.slice(0, 4)].filter(Boolean); });
(async () => {
  const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
    setArea('18. Team screens render (' + scheme + ', 375px)');
    const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme, viewport: { width: 375, height: 760 } }); p.on('dialog', d => d.accept());
    await go(p, '#admin', 2000);
    const tabs = await p.$$eval('[data-atab]', x => x.map(b => b.dataset.atab));
    for (const t of tabs) { await tab(p, t); const subs = await p.$$eval('[data-asub]', x => x.map(b => b.dataset.asub));
      for (const s of subs.length ? subs : [null]) { if (s) await tab(p, t, s); const v = await view(p); const of = await overflow(p);
        ok(v.length > 60 && of.length === 0, '18.' + t + (s ? '/' + s : ''), 'renders, nothing off the edge', of.join(' ')); } }
    ok(p.errs.length === 0, '18.x', 'no page errors', p.errs.join(' | ')); await p.context().close();
  }

  setArea('19. Team actions');
  let p = await phone(b, { time: '2026-11-09T09:00:00Z' }); p.on('dialog', d => d.accept());
  await go(p, '#admin', 2000);
  // building request approve
  await tab(p, 'buildings', 'requests'); let v = await view(p); ok(/Silver Star/.test(v), '19.01', 'new building request listed');
  const ap = p.locator('[data-site="s4"] [data-act="site-approve"]');
  if (!(await ap.count())) await p.locator('[data-site="s4"] summary').first().click().catch(() => {});
  if (await p.locator('[data-site="s4"] [data-act="site-approve"]').count()) { await p.locator('[data-site="s4"] [data-act="site-approve"]').click(); await p.waitForTimeout(900); }
  const s4 = await p.evaluate(() => ((S.admin && S.admin.sites) || S.sites || []).find(s => s.id === 's4')); ok(s4 && s4.status === 'active', '19.02', 'building approved', s4 && s4.status);
  // add a building with the form
  await tab(p, 'buildings', 'list'); const sf = p.locator('form[data-form="site"]'); if (!(await sf.count())) { const add = p.locator('button', { hasText: /Add a building|Add building/ }); if (await add.count()) { await add.first().click(); await p.waitForTimeout(500); } }
  if (await p.locator('form[data-form="site"]').count()) {
    const f = p.locator('form[data-form="site"]').first(); await f.locator('[name=name]').fill('Ab'); await f.locator('button.btn, button[type=submit]').last().click(); await p.waitForTimeout(400);
    ok(/Add the building name/.test(await f.innerText()), '19.03', 'building form checks the name');
    await f.locator('[name=name]').fill('Kofi Annan Towers, Airport'); await f.locator('[name=drop_point]').fill('Front desk'); await f.locator('button.btn, button[type=submit]').last().click(); await p.waitForTimeout(900);
    ok(await p.evaluate(() => S.sites.some(s => /Kofi Annan/.test(s.name))), '19.04', 'building added');
  } else ok(false, '19.03', 'add-building form not found');
  // vendor
  await tab(p, 'menus');
  if (!(await p.locator('form[data-form="kitchen"]').count())) { const add = p.locator('button', { hasText: /Add a vendor|Add vendor/ }); if (await add.count()) { await add.first().click(); await p.waitForTimeout(600); } }
  if (await p.locator('form[data-form="kitchen"]').count()) {
    const f = p.locator('form[data-form="kitchen"]').first();
    await f.locator('[name=name]').fill('Mama Esi Chop Bar'); await f.locator('[name=public_name]').fill('Chop bar classics'); await f.locator('[name=whatsapp]').fill('12345');
    await f.locator('button.btn').last().click(); await p.waitForTimeout(500); ok(/10-digit WhatsApp/.test(await f.innerText()), '19.05', 'vendor form checks WhatsApp');
    await f.locator('[name=whatsapp]').fill('0244556677'); await f.locator('button.btn').last().click(); await p.waitForTimeout(1000);
    ok(await p.evaluate(() => (S.menus || []).some(k => /Chop bar classics/.test(k.public_name)) || (S.admin && (S.admin.kitchens || []).some(k => /Mama Esi/.test(k.name)))), '19.06', 'vendor added');
  } else ok(false, '19.05', 'add-vendor form not found');
  // rider sign-up page then approve
  await go(p, '#rider-signup', 1300); v = await view(p); note('Rider sign-up page: ' + v.slice(0, 200));
  const ins = await p.$$eval('#view input, #view select', x => x.map(i => i.id || i.name)); note('Rider sign-up fields: ' + ins.join(', '));
  if (ins.length) { for (const [sel, val] of [['#rsName', 'Yaw Mensah'], ['#rsPhone', '0244001122'], ['#rsCard', 'GHA-123456789-0'], ['#rsLic', 'DL123456'], ['#rsExp', '2028-06-30']]) await p.fill(sel, val).catch(() => {});
    await p.locator('#view .btn').last().click(); await p.waitForTimeout(900); note('After rider sign-up: ' + (await view(p)).slice(0, 200)); }
  await go(p, '#admin', 1800); await tab(p, 'riders', 'apply'); v = await view(p);
  const pend = p.locator('[data-act="rider-approve"]'); ok(await pend.count() > 0, '19.07', 'rider application waiting for approval', v.slice(0, 200));
  if (await pend.count()) { await p.locator('[data-rider]', { has: pend }).first().locator('summary').click().catch(() => {}); await pend.first().click(); await p.waitForTimeout(900); ok(/Rider approved/.test(await txt(p, '#sheet')), '19.08', 'approve gives the rider link'); await p.evaluate(() => closeSheet()); }
  // settings validation
  await tab(p, 'settings'); const sfm = p.locator('form[data-form="settings"]');
  if (await sfm.count()) { await sfm.locator('[name=quote_pay_min]').fill('5'); await sfm.locator('button.btn').last().click(); await p.waitForTimeout(400); ok(/10 to 20 minutes/.test(await sfm.innerText()), '19.09', 'settings refuse silly values');
    await sfm.locator('[name=quote_pay_min]').fill('15'); await sfm.locator('button.btn').last().click(); await p.waitForTimeout(700); }
  // team
  await tab(p, 'team'); const tf = p.locator('form[data-form="team"]');
  if (await tf.count()) { await tf.locator('[name=email]').fill('kojo@choppool.com'); await tf.locator('button.btn').last().click(); await p.waitForTimeout(800); ok(/kojo@choppool.com/.test(await view(p)), '19.10', 'coordinator added to team'); } else ok(false, '19.10', 'team form not found');
  // refunds: a paid guest whose vendor stops cooking -> refund to send
  await p.clock.setSystemTime(new Date('2026-11-09T10:40:00Z'));
  const rf = await p.evaluate(async () => { const d = '2026-11-10'; await api.kitchenPause('demok2', d, true).catch(() => {}); await api.kitchenPause('demok2', d, false); const it = S.items.find(i => i.kitchen_id === 'k2'); const r = await api.placeOrder({ site: 's1', item: it.id, qty: 1, name: 'Guest Gifty', phone: '0277000111', ref: '58889990001' }); await api.updateOrder(r.id, { status: 'paid' }); await api.kitchenSkipDay('demok2', d); return r.id; });
  await go(p, '#order', 600); await go(p, '#admin', 1800); await tab(p, 'today', 'wallets'); if (await p.locator('[data-aday="2026-11-10"]').count()) { await p.click('[data-aday="2026-11-10"]'); await p.waitForTimeout(900); } v = await view(p);
  ok(/Guest Gifty/.test(v), '19.11', 'refund to send is listed', v.slice(0, 300));
  const rform = p.locator(`form[data-form="refund"][data-id="${rf}"]`);
  if (await rform.count()) { await rform.locator('[name=ref]').fill('RF12345'); await rform.locator('button').last().click(); await p.waitForTimeout(900); const o = await p.evaluate(async id => (await api.myOrders([id]))[0], rf); ok(!o.refund_needed, '19.12', 'refund recorded', JSON.stringify({ n: o.refund_needed })); } else ok(false, '19.12', 'refund form not found');
  ok(p.errs.length === 0, '19.x', 'no page errors', p.errs.join(' | '));

  setArea('20. Coordinator vs owner');
  const own = { wallet: await p.locator('form[data-form="credit"]').count() };
  await p.evaluate(() => { S.role = 'coordinator'; renderAdmin(true); }); await p.waitForTimeout(800);
  await tab(p, 'today', 'wallets'); ok(await p.locator('form[data-form="credit"]').count() === 0, '20.01', 'coordinator can\'t adjust wallets (owner had it: ' + own.wallet + ')');
  await tab(p, 'today', 'owed'); await p.waitForTimeout(800); ok(await p.locator('form[data-form="payout"]').count() === 0, '20.02', 'coordinator can\'t record payouts');
  const tt = await p.$$eval('[data-atab]', x => x.map(b => b.dataset.atab)); note('Coordinator tabs: ' + tt.join(', '));
  await tab(p, 'settings'); const vf = await p.locator('[name=vendor_fee_pct]').count(); ok(vf === 0, '20.03', 'coordinator can\'t change vendor fee');
  await tab(p, 'today', 'orders'); ok(await p.locator('select[data-order]').count() > 0 || await p.locator('[data-act="pay-issue"]').count() > 0, '20.04', 'coordinator can still check payments');
  ok(p.errs.length === 0, '20.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('21. Vendor own menu and settings');
  p = await phone(b, { time: '2026-11-09T07:00:00Z' }); p.on('dialog', d => d.accept());
  await go(p, '#kitchen-demok1', 1500); v = await view(p);
  note('Vendor page sections: ' + (await p.$$eval('#view h2', x => x.map(h => h.innerText))).join(' | '));
  const med = p.locator('[data-medit]'); ok(await med.count() > 0, '21.01', 'vendor can edit their menu');
  if (await med.count()) { const price = med.first().locator('input[data-f=price], input[name=price], input[inputmode=decimal]').first(); const old = await price.inputValue().catch(() => ''); await price.fill('0').catch(() => {});
    const save = p.locator('[data-msave]').first(); if (await save.count()) { await save.click(); await p.waitForTimeout(600); note('Save menu with price 0: ' + (await txt(p, '[data-medit]')).slice(-160)); } await price.fill(old || '45').catch(() => {}); }
  ok(await p.locator('[data-autopick]').count() > 0, '21.02', 'vendor can set auto days');
  ok(p.errs.length === 0, '21.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  require('fs').writeFileSync('/tmp/e2e/res-admin.json', JSON.stringify(results, null, 1));
  await b.close();
})();
