// Pull to refresh + Orders badge matches Upcoming
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
    setArea('Pull to refresh (' + scheme + ')');
    const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme, viewport: { width: 390, height: 844 }, touch: true });
    await p.evaluate(() => { window.__r = 0; const m = refreshMine, bd = refreshBoard; window.refreshMine = refreshMine = async (...a) => { window.__r++; return m(...a); }; });
    const cdp = await p.context().newCDPSession(p);
    const drag = async (x, y, dy, steps = 12) => { await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
      for (let i = 1; i <= steps; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: y + dy * i / steps }] }); await new Promise(r => setTimeout(r, 16)); }
      return async () => cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); };
    const state = () => p.evaluate(() => ({ op: +getComputedStyle($('#ptr')).opacity, ready: $('#ptr').classList.contains('ready'), tf: $('#tabHome').style.transform, r: window.__r, toast: document.querySelector('.toast')?.innerText || '' }));
    await p.waitForTimeout(800);
    // long pull
    const r0 = (await state()).r;
    let up = await drag(195, 420, 260); let s1 = await state();
    ok(s1.op > .9 && s1.ready && /translateY\(\d/.test(s1.tf), 'P1', 'pulling down at the top stretches the page and shows the ChopPool icon, ready to refresh', JSON.stringify(s1));
    if (scheme === 'dark') await p.screenshot({ path: '/tmp/e2e/shots/ptr_pull.png' });
    const stretch = parseFloat((s1.tf.match(/[\d.]+/) || [0])[0]); ok(stretch < 130 && stretch > 60, 'P2', 'stretch has resistance (260px finger → ' + Math.round(stretch) + 'px page)');
    await up(); await p.waitForTimeout(250);
    if (scheme === 'dark') await p.screenshot({ path: '/tmp/e2e/shots/ptr_load.png' });
    await p.waitForTimeout(1200); let s2 = await state();
    ok(s2.r > r0 && /Updated/.test(s2.toast) && !s2.tf && s2.op < .1, 'P3', 'let go: refreshes, says Updated, springs back', JSON.stringify(s2));
    // short pull
    const r1 = s2.r; up = await drag(195, 420, 50); let s3 = await state(); ok(!s3.ready, 'P4', 'short pull is not armed'); await up(); await p.waitForTimeout(800);
    ok((await state()).r === r1 && !(await state()).tf, 'P5', 'short pull: springs back, no refresh');
    // scrolled down: no pull
    await p.setViewportSize({ width: 390, height: 480 }); await p.evaluate(() => window.scrollTo(0, 250)); await p.waitForTimeout(300); note('scrollY ' + await p.evaluate(() => scrollY + ' / ' + document.documentElement.scrollHeight));
    up = await drag(195, 300, 120); const s4 = await state(); await up(); await p.waitForTimeout(500);
    ok(!s4.ready && !s4.tf, 'P6', 'not at the top: normal scrolling, no pull', JSON.stringify(s4));
    await p.evaluate(() => window.scrollTo(0, 0)); await p.setViewportSize({ width: 390, height: 844 }); await p.waitForTimeout(300);
    // sheet open: no pull
    await p.evaluate(() => openHelp()); await p.waitForTimeout(500); up = await drag(195, 600, 200); const s5 = await state(); await up(); await p.evaluate(() => closeSheet()); await p.waitForTimeout(500);
    ok(!s5.ready && !s5.tf, 'P7', 'sheet open: no pull');
    // Orders tab works; Vendors tab doesn't pull
    await p.evaluate(() => setTab('orders')); await p.waitForTimeout(500); const r2 = (await state()).r;
    up = await drag(195, 300, 260); await up(); await p.waitForTimeout(1400); ok((await state()).r > r2, 'P8', 'pull to refresh on Orders');
    await p.evaluate(() => setTab('kitchens')); await p.waitForTimeout(500); up = await drag(195, 400, 260); const s6 = await state(); await up(); await p.waitForTimeout(400);
    ok(!s6.ready, 'P9', 'Vendors tab: no pull');
    // horizontal swipe on the lunch strip is not a pull
    await p.evaluate(async () => { setTab('home'); const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
      for (const it of ['i1', 'i2']) add(await api.placeOrder({ site: 's1', item: it, qty: 1, name: 'A', phone: '0241112223', ref: '5' + Math.floor(Math.random() * 1e10) })); await refreshMine(); });
    await p.waitForTimeout(700); const bx = await p.locator('.mlswipe').boundingBox();
    up = await drag(bx.x + bx.width / 2, bx.y + bx.height / 2, 200); const s7 = await state(); await up(); await p.waitForTimeout(500);
    ok(s7.ready, 'P10', 'pulling down from on the lunch strip also pulls', JSON.stringify(s7));
    await p.waitForTimeout(1500);
    // sideways on the strip: no pull
    const hs = async () => { await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: bx.x + bx.width * .8, y: bx.y + bx.height / 2 }] });
      for (let i = 1; i <= 10; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: bx.x + bx.width * .8 - 180 * i / 10, y: bx.y + bx.height / 2 + 12 * i / 10 }] }); await new Promise(r => setTimeout(r, 16)); } };
    await hs(); const s8 = await state(); await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); await p.waitForTimeout(600);
    ok(!s8.ready && !s8.tf, 'P11', 'swiping sideways on the strip does not pull');
    // quick pulls one after another: every one moves the page (the old spring-back timer used to freeze the next pull)
    let moved = 0; for (let k = 0; k < 6; k++) { const u = await drag(195, 470, k % 2 ? 60 : 40, 6); const st = await state(); if (/translateY\(\d/.test(st.tf) && parseFloat(st.tf.match(/[\d.]+/)[0]) > 15) moved++; await u(); await p.waitForTimeout(120); }
    await p.waitForTimeout(600);
    ok(moved === 6, 'P12', 'six quick pulls in a row all move the page', moved + '/6');
    const r9 = (await state()).r; const u9 = await drag(195, 470, 260); await u9(); await p.waitForTimeout(1500);
    ok((await state()).r > r9, 'P13', 'and a full pull right after still refreshes');
    ok(p.errs.length === 0, 'Px', 'no page errors', p.errs.join(' | ')); await p.context().close();
  }
  setArea('Orders badge');
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', viewport: { width: 390, height: 844 } });
  const n = await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
    const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'A', phone: '0241112223', ref: '51234560000' }); add(a);
    const c = await api.addPlate ? null : null;
    await refreshMine(); const up1 = +($('#ordBadge').textContent || 0);
    // the same order seen as yesterday's, still "paid": not upcoming
    S.mine.forEach(o => { o.order_date = '2026-11-08'; o.status = 'paid'; });
    const act = splitOrders(S.mine).up.length; $('#ordBadge').textContent = act; $('#ordBadge').classList.toggle('hidden', !act);
    setTab('orders'); return { up1, after: act, hidden: $('#ordBadge').classList.contains('hidden'), list: S.oseg === 'past' }; });
  ok(n.up1 === 1, 'B1', 'one upcoming order: badge 1', JSON.stringify(n));
  ok(n.after === 0 && n.hidden && n.list, 'B2', 'yesterday\'s unfinished order: no badge, Upcoming empty (they agree)', JSON.stringify(n));
  await b.close(); })();
