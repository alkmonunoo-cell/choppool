const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['dark', 'light']) {
  const p = await phone(b, { time: '2026-11-09T08:40:00Z', scheme, viewport: { width: 390, height: 844 }, me: { name: 'Albert', phone: '0244111222' } });
  await p.evaluate(async () => { await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Kofi', phone: '0244111333', ref: '5123456782' }); await refreshBoard(); renderHero(); });
  await p.waitForTimeout(800); await p.locator('#hero').screenshot({ path: `/tmp/e2e/shots27/hero3-${scheme}.png` });
  if (scheme === 'dark') { ok(/lowest now/.test(await txt(p, '#hero')), 'h.1', 'join tile says lowest now', await txt(p, '#hero'));
    await p.click('[data-gopools]'); await p.waitForTimeout(700);
    ok(await p.evaluate(() => S.tab === 'kitchens' && S.vf === 'pools'), 'h.2', 'active pools opens Vendors › Pools open');
    ok(await p.evaluate(() => document.title) === 'ChopPool · Order together, pay less', 'h.3', 'no full stop in the tagline'); }
  console.log(p.errs); await p.context().close(); }
  await b.close(); })();
