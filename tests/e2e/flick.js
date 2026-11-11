const { chromium, phone, ok } = require('./h');
(async () => { const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T09:00:00Z' });
  await p.evaluate(async () => { for (let i = 0; i < 3; i++) await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama ' + i, phone: '024411120' + i, ref: '512345671' + i }); });
  await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(2000);
  // freeze the demo (it adds pretend customers over time) and shuffle rows like the server can
  await p.evaluate(async () => { const snap = JSON.parse(JSON.stringify(await api.adminData(S.adminDate || today()))); window.__real = api.adminData.bind(api);
    api.adminData = async () => { const d = JSON.parse(JSON.stringify(snap)); d.orders.reverse(); d.items.reverse(); return d; }; });
  for (const tab of ['dash', 'today']) {
    await p.evaluate(t => document.querySelector(`[data-atab="${t}"]`).click(), tab); await p.waitForTimeout(800);
    await p.evaluate(() => { window.__first = document.querySelector('#aBody').firstElementChild; window.__muts = 0; new MutationObserver(m => { window.__muts += m.filter(x => x.target.id !== 'aUpdated' && !x.target.closest?.('#aUpdated')).length; }).observe(document.querySelector('#aBody'), { childList: true, subtree: true }); });
    await p.clock.runFor(95000); await p.waitForTimeout(1500);
    const r = await p.evaluate(() => [document.querySelector('#aBody').firstElementChild === window.__first, window.__muts]);
    ok(r[0] && r[1] === 0, 'f.' + tab, tab + ': 95 s with nothing new, no redraw', JSON.stringify(r));
  }
  // something new does show up
  await p.evaluate(async () => { api.adminData = window.__real; await api.placeOrder({ site: 's1', item: 'i1', qty: 2, name: 'New Person', phone: '0244111299', ref: '5123456799' }); });
  await p.clock.runFor(35000); await p.waitForTimeout(1500);
  ok(await p.evaluate(() => window.__muts > 0), 'f.new', 'a new order still appears on its own');
  console.log(p.errs); await b.close(); })();
