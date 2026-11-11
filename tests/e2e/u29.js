// Pools you're in stay listed, checkout delivery wording, am/pm times set in Settings
const { chromium, phone, ok, txt } = require('./h');
const go = async (p, h, w = 1500) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
(async () => {
  const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', me: { name: 'Albert', phone: '0244111222' } });
  // am/pm on home
  const hero = await txt(p, '#hero');
  ok(/Order by 10:30 am · lunch at 12:30 pm/.test(hero), 'u.1', 'home shows am/pm', hero.slice(0, 120));
  // checkout wording: starting a pool
  await p.evaluate(async () => { await api.vendorSetCapacity('demok1', 6, null, true); Object.assign(S, await api.load()); await refreshBoard(); });
  await p.evaluate(() => openVendor('k1')); await p.waitForTimeout(700);
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(300); await p.click('#dAdd'); await p.waitForTimeout(300);
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(600);
  const s1 = await txt(p, '#sum');
  ok(/Delivery \(full trip\)/.test(s1) && /Up to GHS [\d.]+ cash back as others join/.test(s1), 'u.2', 'starting: up to ... cash back as others join', s1.slice(0, 200));
  ok(/What the pool saves on delivery comes back to your ChopPool wallet once you've got your lunch/.test(await txt(p, '#sheet')), 'u.3', 'bottom line kept');
  await p.fill('#fRef', '5123456790'); await p.click('#submitBtn', { force: true }); await p.waitForTimeout(1200);
  await p.evaluate(() => { closeSheet(); closeVendor(); }); await p.waitForTimeout(400);
  // someone else joins: their checkout shows the share right now
  await p.evaluate(() => { local.set('cp_me', { name: 'Esi', phone: '0244111444' }); }); const mineSaved = await p.evaluate(() => local.get('cp_orders'));
  await p.evaluate(() => { local.set('cp_orders', []); S.mine = []; renderPools(); openVendor('k1'); }); await p.waitForTimeout(700);
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(300); await p.click('#dAdd'); await p.waitForTimeout(300);
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(600);
  const s2 = await txt(p, '#sum');
  ok(/Your share right now: GHS [\d.]+\. The rest comes back to your wallet/.test(s2) && !/cash back as others join/.test(s2), 'u.4', 'joining: share right now, rest to wallet', s2.slice(0, 200));
  await p.evaluate(() => { closeSheet(); closeVendor(); }); await p.waitForTimeout(400);
  // back as Albert: fill pool 1 then start pool 2; both your pools stay listed
  await p.evaluate(async saved => { local.set('cp_me', { name: 'Albert', phone: '0244111222' }); local.set('cp_orders', saved);
    await api.placeOrder({ site: 's1', item: 'i1', qty: 5, name: 'Kofi', phone: '0244111333', ref: '5123456782' });
    const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Albert', phone: '0244111222', ref: '5123456783' });
    local.set('cp_orders', [...saved, { id: a.id, order_date: a.order_date }]); await refreshBoard(); await refreshMine(); renderPools(); }, mineSaved);
  await p.waitForTimeout(600);
  const rows = (await p.$$eval('#pools .prow', x => x.map(e => e.innerText.replace(/\s+/g, ' ')))).filter(r => /Local favourites/.test(r));
  ok(rows.length === 2 && /Your pool 1/.test(rows[0]) && /Pool full/.test(rows[0]) && /Your pool 2/.test(rows[1]) && /Add/.test(rows[1]), 'u.5', 'both your pools listed: full pool 1, open pool 2', rows.join(' || '));
  ok(/\(lowest now\)/.test(await txt(p, '#hero')) || !(await p.locator('.lown').count()), 'u.6', '(lowest now) in brackets');
  // Settings: ordering times (owner)
  await go(p, '#admin', 1800); await p.evaluate(() => document.querySelector('[data-atab="settings"]').click()); await p.waitForTimeout(600);
  await p.fill('[name=cutoff]', '11:00'); await p.fill('[name=delivery_time]', '11:30');
  await p.locator('form', { has: p.locator('[name=cutoff]') }).locator('.savebar .btn').click(); await p.waitForTimeout(500);
  ok(/at least an hour/.test(await txt(p, 'form:has([name=cutoff]) [data-err]')), 'u.7', 'lunch must be an hour after the cut-off');
  await p.fill('[name=delivery_time]', '13:00'); await p.locator('form', { has: p.locator('[name=cutoff]') }).locator('.savebar .btn').click(); await p.waitForTimeout(700);
  ok(await p.evaluate(() => String(S.settings.cutoff).startsWith('11:00') && String(S.settings.delivery_time).startsWith('13:00')), 'u.8', 'times saved');
  await go(p, '#order', 1500);
  ok(/Order by 11:00 am · lunch at 1:00 pm/.test(await txt(p, '#hero')), 'u.9', 'home follows the new times', (await txt(p, '#hero')).slice(0, 120));
  ok(p.errs.length === 0, 'u.x', 'no page errors', p.errs.join(' | '));
  await b.close();
})();
