const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', viewport: { width: 390, height: 700 }, me: { name: 'Albert', phone: '0244111222' } });
  await p.evaluate(async () => {
    const ids = [];
    for (const [k, it] of [['k1', 'i1'], ['k2', 'i3'], ['k1', 'i2']]) { const a = await api.placeOrder({ site: 's1', item: it, qty: 1, name: 'Albert', phone: '0244111222', ref: '5123456781' }); ids.push({ id: a.id, order_date: a.order_date }); }
    local.set('cp_orders', ids);
    for (const o of (await api.adminData(ids[0].order_date)).orders) await api.updateOrder(o.id, { status: 'paid' });
    await refreshBoard(); await refreshMine(); renderHero(); });
  await p.waitForTimeout(700);
  const cards = await p.$$eval('#hero .mylunch', x => x.map(e => e.dataset.gomine));
  await p.evaluate(id => { const sw = document.querySelector('.mlswipe'); const el = document.querySelector(`.mylunch[data-gomine="${id}"]`); sw.scrollLeft = el.offsetLeft; }, cards[cards.length - 1]);
  await p.waitForTimeout(500);
  await p.locator(`.mylunch[data-gomine="${cards[cards.length - 1]}"]`).click(); await p.waitForTimeout(900);
  const vis = await p.evaluate(id => { const o = S.mine.find(x => x.id === id); const c = document.querySelector(`#tabOrders [data-ocard="${id}"]`) || document.querySelector(`#tabOrders [data-ocode="${o.code}"]`); if (!c) return 'no card'; const r = c.getBoundingClientRect(); return [S.tab, r.top >= -5 && r.top < innerHeight - 100, c.classList.contains('flash')].join(','); }, cards[cards.length - 1]);
  ok(/^orders,true,true$/.test(vis), 'g.1', 'tapping the strip opens Orders at that order, flashed', vis);
  await p.evaluate(() => { api.confirmReceived = async () => { throw new Error('Order not found.'); }; const bt = document.createElement('button'); bt.dataset.gotit = S.mine[0].id; bt.id = 'fakeGot'; bt.textContent = 'Got my food'; document.querySelector('#tabOrders').prepend(bt); });
  await p.click('#fakeGot'); await p.waitForTimeout(700);
  ok(/sign-in on this phone has expired/.test(await txt(p, '#sheet')), 'g.2', 'Got my food with a lapsed sign-in asks you to sign in', await txt(p, '#sheet'));
  console.log(p.errs); await b.close(); })();
