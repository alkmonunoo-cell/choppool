// Confirmation after a tray order, with the reply shaped like the live server's (no pool details)
const { chromium, phone, ok, txt } = require('./h');
(async () => {
  const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', me: { name: 'Albert', phone: '0244111222' } });
  await p.evaluate(async () => {
    const real = api.placeBasket.bind(api);
    api.placeBasket = async r => { const x = await real(r); return { id: x.id, code: x.code, ids: x.ids, total: x.total, wallet_used: x.wallet_used, momo_due: x.momo_due, status: x.status, order_date: x.order_date }; };
    await api.vendorSetCapacity('demok1', 6, null, true); Object.assign(S, await api.load());
    await api.placeOrder({ site: 's1', item: 'i1', qty: 5, name: 'Kofi', phone: '0244111333', ref: '5123456782' }); await refreshBoard(); renderPools();
  });
  // Pool 1 has 5 of 6: a 2-meal tray starts pool 2
  const order = async n => { await p.evaluate(() => openVendor('k1')); await p.waitForTimeout(700);
    await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(300); for (let i = 1; i < n; i++) await p.click('#dPlus');
    await p.click('#dAdd'); await p.waitForTimeout(300); await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(600);
    const btn = await txt(p, '#submitBtn'); await p.fill('#fRef', '5123456790').catch(() => {}); await p.click('#submitBtn', { force: true }); await p.waitForTimeout(1200); return btn; };
  const b1 = await order(2); const c1 = await txt(p, '#sheet');
  ok(/Start pool/.test(b1), 'c.1', 'checkout says Start pool', b1);
  ok(/You've started pool 2/.test(c1) && !/undefined/.test(c1) && !/GHS 0\.00 a meal/.test(c1), 'c.2', 'confirmation: started pool 2, no undefined, no GHS 0', c1.slice(0, 220));
  ok(await p.locator('#sharePool').count() === 1, 'c.3', 'share button right away');
  await p.evaluate(() => { closeSheet(); closeVendor(); }); await p.waitForTimeout(500);
  // Someone else joins pool 2 with a 1-meal tray
  await p.evaluate(() => { local.set('cp_me', { name: 'Esi', phone: '0244111444' }); local.set('cp_orders', []); S.mine = []; renderPools(); });
  const b2 = await order(1); const c2 = await txt(p, '#sheet');
  ok(/Join pool/.test(b2) && /You're in the pool/.test(c2) && /6 of 6 meals are in/.test(c2), 'c.4', 'joining the last seat of pool 1: in the pool, 6 of 6', b2 + ' | ' + c2.slice(0, 200));
  ok(!/more (person|people)/.test(c2) && await p.locator('#sharePool').count() === 0, 'c.4b', 'full pool: no "more people" line and no share button');
  const sum = await p.evaluate(() => document.body.innerHTML.includes('What others save you'));
  ok(!sum, 'c.5', 'old cashback wording gone');
  ok(p.errs.length === 0, 'c.x', 'no page errors', p.errs.join(' | '));
  await b.close();
})();
