const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['dark', 'light']) {
    setArea('Strip ' + scheme);
    const p = await phone(b, { time: '2026-11-09T16:00:00Z', scheme, viewport: { width: 390, height: 844 } });
    // one order: no swipe
    await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
      await api.kitchenPause('demok1', '2026-11-10', true); await api.kitchenPause('demok1', '2026-11-10', false);
      const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Albert', phone: '0241112223', ref: '51234567890' }); await api.updateOrder(a.id, { status: 'paid' }); add(a);
      await refreshBoard(); await refreshMine(); });
    await p.waitForTimeout(800);
    let t = await txt(p, '#hero .mylunch'); ok(/Paid · waiting for vendor/.test(t) && /Confirms by 08:30 tomorrow/.test(t), 'S1', 'waiting vendor: strip no longer says "Confirmed"', t.replace(/\n/g, ' | '));
    ok(await p.locator('#mlSwipe').count() === 0, 'S2', 'one order: no swipe, no dots');
    // more orders
    await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
      const k2 = S.items.find(i => i.kitchen_id === 'k2'); const b = await api.placeOrder({ site: 's1', item: k2.id, qty: 2, name: 'Albert', phone: '0241112223', ref: '51234567891' }); await api.updateOrder(b.id, { status: 'paid' }); add(b);
      const c = await api.placeOrder({ site: 's1', item: 'i2', qty: 1, name: 'Albert', phone: '0241112223', ref: '51234567892' }); add(c);
      await refreshBoard(); await refreshMine(); });
    await p.waitForTimeout(900);
    const cards = await p.$$eval('#mlSwipe .mylunch', x => x.map(e => e.innerText.replace(/\n/g, ' ')));
    note('cards: ' + cards.join(' || '));
    ok(cards.length === 3, 'S3', 'three orders: three cards', cards.length);
    ok(await p.locator('.mldots i').count() === 3 && await p.locator('.mldots i.on').count() === 1, 'S4', 'dots show 3, first on');
    await p.locator('#hero').screenshot({ path: `/tmp/e2e/shots/strip_${scheme}.png` });
    // swipe
    await p.evaluate(() => { const s = $('#mlSwipe'); s.scrollLeft = s.firstElementChild.getBoundingClientRect().width + 8; }); await p.waitForTimeout(600); note('scrollLeft ' + await p.evaluate(() => $('#mlSwipe').scrollLeft + ' / ' + $('#mlSwipe').scrollWidth + ' / ' + $('#mlSwipe').clientWidth));
    ok(await p.evaluate(() => [...document.querySelectorAll('.mldots i')].findIndex(i => i.classList.contains('on'))) === 1, 'S5', 'swiping moves the dot');
    await p.waitForTimeout(5000); ok(await p.evaluate(() => [...document.querySelectorAll('.mldots i')].findIndex(i => i.classList.contains('on'))) === 1, 'S5b', 'auto refresh keeps the card you swiped to');
    await p.locator('#hero').screenshot({ path: `/tmp/e2e/shots/strip2_${scheme}.png` });
    const off = await p.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth); ok(!off, 'S6', 'page not wider than phone');
    // tap opens that order
    const id = await p.evaluate(() => document.querySelectorAll('#mlSwipe .mylunch')[1].dataset.gomine);
    await p.evaluate(() => document.querySelectorAll('#mlSwipe .mylunch')[1].click()); await p.waitForTimeout(900);
    ok(await p.evaluate(id => { const c = document.querySelector(`[data-ocard="${id}"]`); if (!c) return false; const r = c.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight + 200; }, id), 'S7', 'tapping a card opens Orders at that order');
    // custom order wording
    await p.evaluate(() => { setTab('home'); openVendor(S.menus.find(k => !['k1','k2'].includes(k.id)).id); }); await p.waitForTimeout(800); await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400);
    ok(/Make a custom order/.test(await txt(p, '#sheet')), 'C1', 'dish sheet: "Make a custom order"');
    await p.click('#dSpecial'); await p.waitForTimeout(700);
    const sh = await txt(p, '#sheet'); ok(/Custom order: something not on the menu\. The vendor sets the price\./.test(sh) && await p.locator('#fSpecial').isVisible(), 'C2', 'checkout explains custom order', sh.slice(0, 200));
    ok(!/special/i.test(sh), 'C3', 'no "special" left on checkout');
    ok(p.errs.length === 0, 'Sx', 'no page errors', p.errs.join(' | ')); await p.context().close(); }
  await b.close(); })();
