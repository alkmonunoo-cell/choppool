// Look and fit: every screen at 360px and 390px, light and dark: nothing off the edge, no text under 12px, no page errors
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
const check = p => p.evaluate(() => {
  const W = document.documentElement.clientWidth, bad = [], tiny = [];
  const scrolls = e => { let a = e.parentElement; while (a && a !== document.body) { if (/auto|scroll|hidden/.test(getComputedStyle(a).overflowX)) return true; a = a.parentElement; } return false; };
  document.querySelectorAll('body *').forEach(e => { const cs = getComputedStyle(e); if (cs.display === 'none' || cs.visibility === 'hidden' || cs.position === 'fixed' && !e.closest('.sheet')) return; const r = e.getBoundingClientRect(); if (!r.width || !r.height || r.bottom < 0) return;
    if (r.right > W + 1 && !scrolls(e) && !e.closest('#vpage:not(.open), .leaflet-container, .toast')) bad.push((e.id ? '#' + e.id : (e.className && e.className.baseVal === undefined ? e.className : e.tagName)).toString().slice(0, 30) + ':' + Math.round(r.right));
    if (e.childNodes.length && [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && parseFloat(cs.fontSize) < 12) tiny.push((e.className || e.tagName).toString().slice(0, 20) + ':' + cs.fontSize + ':' + e.textContent.trim().slice(0, 15)); });
  return { off: [document.documentElement.scrollWidth > W ? 'PAGE ' + document.documentElement.scrollWidth : '', ...bad.slice(0, 4)].filter(Boolean), tiny: tiny.slice(0, 4) };
});
(async () => {
  const b = await chromium.launch();
  for (const w of [360, 390]) for (const scheme of ['light', 'dark']) {
    setArea(`22. Look ${w}px ${scheme}`);
    const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme, viewport: { width: w, height: 780 } });
    // prepare: an order of mine so Orders and the home strip have content
    await p.evaluate(async () => { const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 2, name: 'Ama Owusu', phone: '0241112223', ref: '51234567890' }); await api.updateOrder(r.id, { status: 'paid' }); const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); await refreshMine(); });
    const screens = [
      ['home', async () => p.evaluate(() => setTab('home'))],
      ['vendors', async () => p.evaluate(() => setTab('vendors'))],
      ['orders', async () => p.evaluate(() => setTab('orders'))],
      ['account', async () => p.evaluate(() => setTab('wallet'))],
      ['vendor page', async () => p.evaluate(() => openVendor('k2'))],
      ['dish sheet', async () => { await p.locator('#vpage [data-dish]:not([disabled])').first().click(); }],
      ['checkout', async () => { await p.click('#dAdd'); await p.waitForTimeout(300); await p.locator('#vfoot [data-vcheckout]').click(); }],
      ['payment methods', async () => { await p.evaluate(() => { closeSheet(); closeVendor(true); setTab('wallet'); openPayments(); }); }],
      ['help', async () => { await p.evaluate(() => { closeSheet(); openHelp(); }); }],
      ['vendor screen', async () => { await p.evaluate(() => { closeSheet(); location.hash = '#kitchen-demok1'; }); }],
      ['rider screen', async () => p.evaluate(() => { location.hash = '#rider-demor1'; })],
      ['host screen', async () => p.evaluate(() => { location.hash = '#host-demoh1'; })],
      ['rider sign-up', async () => p.evaluate(() => { location.hash = '#rider-signup'; })],
      ['terms', async () => p.evaluate(() => { location.hash = '#terms'; })],
    ];
    for (const [name, fn] of screens) { try { await fn(); } catch (e) { ok(false, '22.' + name, name + ' could not open', e.message.slice(0, 120)); continue; } await p.waitForTimeout(900); await p.evaluate(() => Promise.all(document.getAnimations().filter(a => a.effect && a.effect.getTiming().iterations !== Infinity).map(a => a.finished.catch(() => {}))));
      const r = await check(p); ok(!r.off.length && !r.tiny.length, '22.' + name, name, [r.off.join(' '), r.tiny.join(' ')].filter(Boolean).join(' | '));
      if (w === 360 && scheme === 'dark') await p.screenshot({ path: `/tmp/e2e/shots/${name.replace(/ /g, '_')}.png` }); }
    ok(p.errs.length === 0, '22.x', 'no page errors', p.errs.join(' | ')); await p.context().close();
  }
  require('fs').writeFileSync('/tmp/e2e/res-look.json', JSON.stringify(results, null, 1));
  await b.close();
})();
