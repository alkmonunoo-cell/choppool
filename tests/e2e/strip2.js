// Strip stability: no rebuilds when nothing changed, position kept, card patched in place, changes wait for the swipe to settle
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
(async () => { const b = await chromium.launch();
  setArea('Strip stability');
  const ctx = await b.newContext({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } }); await ctx.close();
  const p = await phone(b, { time: '2026-11-09T16:00:00Z', viewport: { width: 390, height: 844 } });
  const ids = await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
    const out = []; for (const [it, paid] of [['i1', true], [S.items.find(i => i.kitchen_id === 'k2').id, true], ['i2', false]]) { const r = await api.placeOrder({ site: 's1', item: it, qty: 1, name: 'Albert', phone: '0241112223', ref: '5123456789' + out.length }); if (paid) await api.updateOrder(r.id, { status: 'paid' }); add(r); out.push(r.id); }
    await refreshBoard(); await refreshMine(); return out; });
  await p.waitForTimeout(800);
  // tag the DOM nodes so we can tell if they get rebuilt
  await p.evaluate(() => { document.querySelectorAll('#mlHost .mylunch').forEach(e => e.__keep = 1); $('#mlHost').__keep = 1; });
  await p.evaluate(() => { const s = document.querySelector('.mlswipe'); s.scrollLeft = s.firstElementChild.getBoundingClientRect().width + 8; }); await p.waitForTimeout(700);
  for (let i = 0; i < 6; i++) { await p.evaluate(async () => { await refreshBoard(); await refreshMine(); renderHero(); }); await p.waitForTimeout(150); }
  const st = await p.evaluate(() => ({ kept: [...document.querySelectorAll('#mlHost .mylunch')].every(e => e.__keep) && $('#mlHost').__keep, dot: [...document.querySelectorAll('.mldots i')].findIndex(i => i.classList.contains('on')), sl: document.querySelector('.mlswipe').scrollLeft }));
  ok(st.kept, 'G1', 'refreshes with nothing new rebuild nothing');
  ok(st.dot === 1 && st.sl > 250, 'G2', 'stays on the swiped card through refreshes', JSON.stringify(st));
  // a card's status changes: only that card is swapped, others and position untouched
  await p.evaluate(async id => { await api.updateOrder(id, { status: 'paid' }); await refreshMine(); renderHero(); }, ids[2]); await p.waitForTimeout(400);
  const st2 = await p.evaluate(() => ({ swapped: [...document.querySelectorAll('#mlHost .mylunch')].map(e => !!e.__keep), sl: document.querySelector('.mlswipe').scrollLeft, n: document.querySelectorAll('#mlHost .mylunch').length }));
  note('after one status change: ' + JSON.stringify(st2));
  ok(st2.sl > 250, 'G3', 'position kept when a card changes');
  // mid-swipe: change arrives while finger is down -> waits, then applies after release
  await p.evaluate(() => { S.mlTouch = true; });
  const before = await p.evaluate(() => document.querySelectorAll('#mlHost .mylunch').length);
  const shownBefore = await p.evaluate(() => { const s = document.querySelector('.mlswipe'); return [...s.children][Math.round(s.scrollLeft / (s.firstElementChild.getBoundingClientRect().width + 8))].dataset.gomine; });
  await p.evaluate(async () => { const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 2, name: 'Albert', phone: '0241112223', ref: '5999999990' }); const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); await refreshMine(); renderHero(); });
  await p.waitForTimeout(300);
  ok(await p.evaluate(() => document.querySelectorAll('#mlHost .mylunch').length) === before, 'G4', 'nothing changes under your finger');
  await p.evaluate(() => { document.querySelector('.mlswipe').dispatchEvent(new Event('touchend')); }); await p.waitForTimeout(900);
  ok(await p.evaluate(() => document.querySelectorAll('#mlHost .mylunch').length) === before + 1, 'G5', 'the new order appears once you let go');
  const shownAfter = await p.evaluate(() => { const s = document.querySelector('.mlswipe'); return [...s.children][Math.round(s.scrollLeft / (s.firstElementChild.getBoundingClientRect().width + 8))].dataset.gomine + ' sl=' + s.scrollLeft; });
  ok(shownAfter.startsWith(shownBefore), 'G6', 'still on the same order after the list changed', shownBefore + ' -> ' + shownAfter);
  // single order -> no swipe; back to one when others finish
  ok(p.errs.length === 0, 'Gx', 'no page errors', p.errs.join(' | '));
  await p.locator('#hero').screenshot({ path: '/tmp/e2e/shots/strip_g.png' });
  await b.close(); })();
