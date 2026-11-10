// Real finger swipes (touch gestures with glide) while the app refreshes underneath
const { chromium, results, setArea, ok, note, phone } = require('./h');
(async () => { const b = await chromium.launch();
  setArea('Strip: real touch swipes');
  const p = await phone(b, { time: '2026-11-09T16:00:00Z', viewport: { width: 390, height: 844 }, touch: true });
  await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
    for (const [it, paid] of [['i1', true], [S.items.find(i => i.kitchen_id === 'k2').id, true], ['i2', false]]) { const r = await api.placeOrder({ site: 's1', item: it, qty: 1, name: 'Albert', phone: '0241112223', ref: '5' + Math.floor(Math.random() * 1e10) }); if (paid) await api.updateOrder(r.id, { status: 'paid' }); add(r); }
    await refreshBoard(); await refreshMine(); });
  await p.waitForTimeout(800);
  const cdp = await p.context().newCDPSession(p);
  const box = await p.locator('.mlswipe').boundingBox();
  const swipe = async dx => { dx = Math.sign(dx) * 200; const x0 = box.x + box.width * (dx < 0 ? .8 : .2), y = box.y + box.height / 2;
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x0, y }] });
    for (let i = 1; i <= 8; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x0 + dx * i / 8, y }] }); await new Promise(r => setTimeout(r, 12)); }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); };
  const at = () => p.evaluate(() => { const s = document.querySelector('.mlswipe'); const w = s.firstElementChild.getBoundingClientRect().width + 8; const mx = s.scrollWidth - s.clientWidth, i = Math.round(s.scrollLeft / w); return { i, off: Math.min(Math.abs(s.scrollLeft - i * w), Math.abs(s.scrollLeft - mx)), dot: [...document.querySelectorAll('.mldots i')].findIndex(d => d.classList.contains('on')), tab: S.tab }; });
  // keep refreshing hard while swiping (like the 4 s demo refresh, but every 120 ms)
  await p.evaluate(() => { window.__hammer = setInterval(() => { refreshMine(); refreshBoard(); renderHero(); }, 120); });
  let fine = true, log = [];
  for (const [dx, want] of [[-1, 1], [-1, 2], [1, 1], [1, 0], [-1, 1], [-1, 2], [-1, 2], [1, 1]]) {
    await swipe(dx); await p.waitForTimeout(900); const r = await at(); log.push(JSON.stringify(r));
    if (r.i !== want || r.off > 2 || r.dot !== want || r.tab !== 'home') fine = false;
  }
  await p.evaluate(() => clearInterval(window.__hammer));
  ok(fine, 'T1', 'every swipe lands squarely on the next card, dot follows, no jump back, never opens Orders', log.join(' '));
  // a status change during a glide is applied after it settles, without moving
  await swipe(1); await p.waitForTimeout(900); await swipe(-1); await p.evaluate(async () => { const o = S.mine.find(o => o.status === 'pending' && !o.parent_id); await api.updateOrder(o.id, { status: 'paid' }); await refreshMine(); renderHero(); });
  await p.waitForTimeout(1200); const r2 = await at(); ok(r2.i === 1 && r2.off <= 2, 'T2', 'change during a glide waits, then lands without moving', JSON.stringify(r2));
  // a clean tap still opens the order
  await p.tap('.mlswipe .mylunch >> nth=1'); await p.waitForTimeout(700);
  ok(await p.evaluate(() => S.tab) === 'orders', 'T3', 'a clean tap opens Orders');
  ok(p.errs.length === 0, 'Tx', 'no page errors', p.errs.join(' | '));
  await b.close(); })();
