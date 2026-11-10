const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
    setArea('Order cards (' + scheme + ')');
    const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme, viewport: { width: 390, height: 844 } }); p.on('dialog', d => d.accept());
    const ids = await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
      const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 3, name: 'Albert', phone: '0241112223', ref: '51234560000' }); await api.updateOrder(a.id, { status: 'paid' }); add(a);
      const kids = []; for (let i = 0; i < 3; i++) { const c = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Albert', phone: '0241112223', ref: '5123456000' + (i + 1), join: a.id }); await api.updateOrder(c.id, { status: 'paid' }); kids.push(c.id); }
      const k2 = S.items.find(i => i.kitchen_id === 'k2'); const b2 = await api.placeOrder({ site: 's1', item: k2.id, qty: 2, name: 'Albert', phone: '0241112223', ref: '51234569999' }); await api.updateOrder(b2.id, { status: 'paid' }); add(b2);
      await refreshMine(); setTab('orders'); return { a: a.id, kids, b: b2.id }; });
    await p.waitForTimeout(900);
    const card = p.locator(`[data-ocard="${ids.a}"]`); const ct = await card.innerText();
    ok(/6 × /.test(ct), 'O1', 'grouped: 6 plates on one line', ct.split('\n').slice(0, 4).join(' | '));
    ok(!/Remove /.test(ct) && /Cancel whole order/.test(ct), 'O2', 'no repeated "Remove" links; one "Cancel whole order"');
    ok(await card.locator('.minus1').count() === 1, 'O3', 'one "−" on the dish line');
    ok(await p.locator('.order-card.next').count() === 0, 'O4', 'no outline when nothing needs you');
    await card.screenshot({ path: `/tmp/e2e/shots/ocard_${scheme}.png` });
    // the tester's case: 3 plates first, then 3 more added in one go
    const ids2 = await p.evaluate(async () => { const add = r => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); };
      const a = await api.placeOrder({ site: 's2', item: 'i1', qty: 3, name: 'Albert', phone: '0241112223', ref: '51234561111' }); await api.updateOrder(a.id, { status: 'paid' }); add(a);
      const c = await api.placeOrder({ site: 's2', item: 'i1', qty: 3, name: 'Albert', phone: '0241112223', ref: '51234561112', join: a.id }); await api.updateOrder(c.id, { status: 'paid' });
      await refreshMine(); renderOrders(); return { a: a.id, c: c.id }; });
    await p.waitForTimeout(500);
    const c2 = p.locator(`[data-ocard="${ids2.a}"]`);
    await c2.locator('.minus1').click(); await p.waitForTimeout(400);
    let sh = await txt(p, '#sheet'); ok(/You have 6 on code/.test(sh) && /Remove 1 plate/.test(sh) && /keep 5/.test(sh), 'O5', 'tap −: choose how many, starts at 1', sh.slice(0, 200));
    await p.click('#lessForm .btn'); await p.waitForTimeout(900);
    let q = await p.evaluate(async ids => { const os = await api.myOrders([ids.a, ids.c]); return [ids.a, ids.c].map(i => os.find(o => o.id === i)).map(o => o.status + ':' + o.qty).join(' '); }, ids2);
    ok(q === 'paid:3 paid:2', 'O6', 'removes just 1 (from the plates added last)', q);
    ok(/5 × /.test(await c2.innerText()), 'O7', 'card now says 5');
    await c2.locator('.minus1').click(); await p.waitForTimeout(400);
    for (let i = 0; i < 3; i++) await p.click('#lpPlus');
    sh = await txt(p, '#sheet'); ok(/Remove 4 plates/.test(sh) && /keep 1/.test(sh), 'O7b', 'can pick 4 (keeps at least 1)');
    ok(await p.locator('#lpPlus').isDisabled(), 'O7c', 'cannot go past what you can remove');
    await p.click('#lessForm .btn'); await p.waitForTimeout(1200);
    q = await p.evaluate(async ids => { const os = await api.myOrders([ids.a, ids.c]); return [ids.a, ids.c].map(i => os.find(o => o.id === i)).map(o => o.status + ':' + o.qty).join(' '); }, ids2);
    ok(q === 'paid:1 cancelled:2', 'O7d', 'remove 4: added plates go, first order keeps 1', q);
    ok(await p.locator(`[data-ocard="${ids2.a}"] .minus1`).count() === 0, 'O7e', 'no − when only 1 plate is left');
    // needs-you outline: payment problem
    await p.evaluate(async id => { await api.updateOrder(id, { status: 'pending' }); await api.setPayIssue?.(id, 'not_found'); }, ids.b).catch(() => {});
    await p.evaluate(async id => { const o = S.mine.find(o => o.id === id); if (o) { o.status = 'pending'; o.pay_issue = 'not_found'; } renderOrders(); }, ids.b); await p.waitForTimeout(400);
    ok(await p.locator(`.order-card.next[data-ocard="${ids.b}"]`).count() === 1 && await p.locator('.order-card.next').count() === 1, 'O8', 'outline appears only on the order that needs you');
    // whole order cancel
    await p.locator(`[data-ocard="${ids.a}"] [data-cancel="${ids.a}"]`).click(); await p.waitForTimeout(400);
    ok(/including the plates you added/.test(await txt(p, '#sheet')), 'O9', 'whole-order cancel says it includes added plates');
    ok(p.errs.length === 0, 'Ox', 'no page errors', p.errs.join(' | ')); await p.context().close(); }
  await b.close(); })();
