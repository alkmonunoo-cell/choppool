// Building picker: never empty on a new phone; nearest first when location is allowed
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
(async () => {
  const b = await chromium.launch();
  for (const [name, opt] of [['new phone, no location', {}], ['location already allowed', { geo: { latitude: 5.5600, longitude: -0.2050 } }]]) for (const scheme of ['light', 'dark']) {
    setArea('Picker: ' + name + ' (' + scheme + ')');
    const p = await phone(b, { time: '2026-11-09T08:00:00Z', site: null, scheme, viewport: { width: 360, height: 760 }, ...opt });
    await p.evaluate(() => openSitePicker()); await p.waitForTimeout(1500);
    const t = await txt(p, '#siteList'); const n = await p.locator('#siteList .siterow').count();
    ok(n >= 3 && n <= 5, 'P1', 'buildings shown before searching', n + ' rows: ' + t.slice(0, 160));
    ok(opt.geo ? /Near you/.test(t) : /Popular on ChopPool/.test(t), 'P2', 'section title fits the case', t.slice(0, 40));
    if (opt.geo) { const ds = await p.$$eval('#siteList .siterow .small', x => x.map(e => e.innerText)); note('distances: ' + ds.join(' | ')); ok(ds.every(d => / m$| km$/.test(d)), 'P3', 'each shows a distance'); }
    const off = await p.evaluate(() => { const W = document.documentElement.clientWidth; return [...document.querySelectorAll('#sheet *')].filter(e => e.getBoundingClientRect().right > W + 1 && !e.closest('.map')).map(e => (e.id || e.className || e.tagName) + ':' + Math.round(e.getBoundingClientRect().right)).join(' '); });
    ok(!off, 'P4', 'nothing off the edge', off);
    await p.fill('#fbQ', 'heritage'); await p.waitForTimeout(500); ok(/Heritage/.test(await txt(p, '#siteList')) && !/Popular|Near you/.test(await txt(p, '#siteList')), 'P5', 'search replaces the list');
    await p.fill('#fbQ', ''); await p.waitForTimeout(400); ok(await p.locator('#siteList .siterow').count() === n, 'P6', 'clearing search brings the list back');
    await p.locator('#siteList .siterow').first().click(); await p.waitForTimeout(900);
    ok(!!(await p.evaluate(() => S.siteId)), 'P7', 'tapping a building picks it');
    await p.evaluate(() => openSitePicker()); await p.waitForTimeout(1200); const t2 = await txt(p, '#siteList');
    ok(/^Recent/.test(t2.trim()) && (await p.locator('#siteList .siterow').count()) <= 5, 'P8', 'next time: Recent first, then the rest', t2.slice(0, 120));
    if (scheme === 'dark') await p.evaluate(() => openSitePicker()).then(() => p.waitForTimeout(1200)).then(() => p.screenshot({ path: `/tmp/e2e/shots/picker_${opt.geo ? 'geo' : 'new'}.png` }));
    if (scheme === 'light' && !opt.geo) { await p.context().close(); const q = await phone(b, { time: '2026-11-09T08:00:00Z', site: null, viewport: { width: 360, height: 760 } }); await q.evaluate(() => openSitePicker()); await q.waitForTimeout(1200); await q.screenshot({ path: '/tmp/e2e/shots/picker_new_light.png' }); await q.context().close(); continue; }
    ok(p.errs.length === 0, 'Px', 'no page errors', p.errs.join(' | ')); await p.context().close();
  }
  await b.close();
})();
