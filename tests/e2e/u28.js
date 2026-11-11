// Update 28: vendor pool size, no daily limit, next pool with the same vendor, home middle box
const fs = require('fs');
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
const go = async (p, h, w = 1500) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
(async () => {
  const b = await chromium.launch();
  setArea('28. Pool size by vendor');
  let p = await phone(b, { time: '2026-11-09T09:00:00Z', me: { name: 'Ama', phone: '0244111222' } });
  // vendor page: the new card saves pool size and no daily limit
  await p.evaluate(() => { S.kset = true; }); await go(p, '#kitchen-demok1', 1800);
  ok(await p.locator('#capForm').count() === 1, '28.01', 'vendor sees meals per pool and per day');
  await p.selectOption('#capPool', '6'); await p.check('#capNoLimit', { force: true });
  ok(await p.locator('#capDay').isDisabled(), '28.02', 'ticking No daily limit turns off the day box');
  await p.click('#capSave'); await p.waitForTimeout(800);
  const head = await txt(p, '#view header');
  ok(/so far/.test(head) && !/of \d+ meals/.test(head), '28.03', 'vendor header drops the daily limit', head.slice(0, 120));
  const bad = await p.evaluate(async () => { try { await api.vendorSetCapacity('demok1', 40, 20, false); return 'saved'; } catch (e) { return e.message; } });
  ok(/between 5 and 15/.test(bad), '28.04', 'vendor can\'t go above the ceiling', bad);
  // customer: fill pool 1 (6 meals), the next pool opens with the same vendor
  await go(p, '#order', 1500);
  await p.evaluate(async () => { Object.assign(S, await api.load());
    const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 4, name: 'Ama', phone: '0244111222', ref: '5123456781' }); local.set('cp_orders', [{ id: a.id, order_date: a.order_date }]);
    await api.placeOrder({ site: 's1', item: 'i1', qty: 2, name: 'Kofi', phone: '0244111333', ref: '5123456782' });
    await refreshBoard(); await refreshMine(); renderPools(); });
  await p.waitForTimeout(600);
  const rows = await p.$$eval('#pools .prow', x => x.map(e => e.innerText.replace(/\s+/g, ' ')));
  const lf = rows.filter(r => /Local favourites/.test(r));
  ok(lf.length === 2 && /6 of 6 meals/.test(lf[0]) && /Pool full/.test(lf[0]), '28.05', 'your full pool shows as full', lf[0]);
  ok(/0 of 6 meals/.test(lf[1] || '') && /pool 2/i.test(lf[1] || '') && /Start pool/.test(lf[1] || ''), '28.06', 'next pool with the same vendor, Start pool', lf[1]);
  const r3 = await p.evaluate(async () => { const x = await api.placeOrder({ site: 's1', item: 'i1', qty: 3, name: 'Esi', phone: '0244111444', ref: '5123456783' }); return x.pool_seq; });
  ok(r3 === 2, '28.07', 'next order lands in pool 2', r3);
  // order bigger than the pool is refused
  const big = await p.evaluate(async () => { try { await api.placeBasket({ site: 's1', lines: [{ item: 'i1', qty: 4 }, { item: 'i2', qty: 3 }], name: 'Yaw', phone: '0244111555', ref: '5123456784' }); return 'placed'; } catch (e) { return e.message; } });
  ok(/Up to 6 meals/.test(big), '28.08', 'order bigger than the pool refused', big);
  // home middle box: active pools
  await p.evaluate(async () => { await refreshBoard(); renderHero(); }); await p.waitForTimeout(400);
  const hero = await txt(p, '#hero');
  ok(/\d+ active pools?/.test(hero), '28.09', 'home shows active pools', hero.slice(0, 160));
  await p.click('[data-gopools]'); await p.waitForTimeout(700);
  ok(await p.evaluate(() => { const r = document.querySelector('#secPools').getBoundingClientRect(); return r.top < 300; }), '28.10', 'tapping it goes to the pools');
  // team settings: default and ceiling
  const tab = async (t, sb) => { await p.evaluate(t => document.querySelector(`[data-atab="${t}"]`)?.click(), t); await p.waitForTimeout(500); if (sb) { await p.evaluate(sb => document.querySelector(`[data-asub="${sb}"]`)?.click(), sb); await p.waitForTimeout(500); } };
  await go(p, '#admin', 1800); await tab('menus', 'rules');
  ok(await p.locator('[name=max_meals]').count() === 1 && await p.locator('[name=pool_ceiling]').count() === 1 && await p.locator('[name=vendor_fee_pct]').count() === 1, '28.11', 'pool size and ChopPool fee under Vendors & menus');
  await tab('riders', 'rules'); ok(await p.locator('[name=base_fare]').count() === 1 && await p.locator('[name=max_meals]').count() === 0, '28.12', 'delivery pricing under Riders');
  await p.fill('[name=base_fare]', '22'); await p.click('form[data-form="settings"] .savebar .btn'); await p.waitForTimeout(700);
  ok(await p.evaluate(() => Number(S.settings.base_fare) === 22 && Number(S.settings.max_meals) === 10), '28.13', 'saving pricing changes only pricing');
  await tab('today', 'rules'); ok(await p.locator('[name=auto_receive_min]').count() === 1, '28.14', 'Got my food timing under Today');
  await tab('settings'); const st = await txt(p, '#aBody');
  ok(/Team screens/.test(st) && !/Base fare/.test(st) && await p.locator('[data-goset]').count() >= 3, '28.15', 'Settings keeps only general settings, with links', st.slice(0, 160));
  await p.locator('[data-goset="riders,rules"]').click(); await p.waitForTimeout(600);
  ok(await p.locator('[name=base_fare]').count() === 1, '28.16', 'link opens Riders › Settings');
  ok(p.errs.length === 0, '28.x', 'no page errors', p.errs.join(' | '));
  await b.close();
  fs.writeFileSync('/tmp/e2e/res-u28.json', JSON.stringify(results, null, 1));
})();
