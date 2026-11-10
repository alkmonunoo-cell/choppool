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
    await card.locator('.minus1').click(); await p.waitForTimeout(400);
    const sh = await txt(p, '#sheet'); ok(/Remove 1 × /.test(sh) && /The rest of your order stays/.test(sh) && /Remove plate/.test(sh), 'O5', 'tap −: "Remove 1 × … ?" sheet', sh.slice(0, 160));
    await p.locator('#cancelForm .btn').click(); await p.waitForTimeout(900);
    const st = await p.evaluate(async ids => { const os = await api.myOrders([...ids.kids, ids.a]); const by = Object.fromEntries(os.map(o => [o.id, o]));
      const kids = ids.kids.map(i => by[i]); const latest = kids.slice().sort((a, b) => a.created_at < b.created_at ? -1 : 1).pop();
      return { main: by[ids.a].status, cancelled: kids.filter(k => k.status === 'cancelled').map(k => k.created_at), latest: latest.created_at }; }, ids);
    ok(st.main === 'paid' && st.cancelled.length === 1 && st.cancelled[0] === st.latest, 'O6', 'removes one added plate (the most recent), main order stays', JSON.stringify(st).slice(0, 120));
    ok(/5 × /.test(await p.locator(`[data-ocard="${ids.a}"]`).innerText()), 'O7', 'card now says 5');
    // needs-you outline: payment problem
    await p.evaluate(async id => { await api.updateOrder(id, { status: 'pending' }); await api.setPayIssue?.(id, 'not_found'); }, ids.b).catch(() => {});
    await p.evaluate(async id => { const o = S.mine.find(o => o.id === id); if (o) { o.status = 'pending'; o.pay_issue = 'not_found'; } renderOrders(); }, ids.b); await p.waitForTimeout(400);
    ok(await p.locator(`.order-card.next[data-ocard="${ids.b}"]`).count() === 1 && await p.locator('.order-card.next').count() === 1, 'O8', 'outline appears only on the order that needs you');
    // whole order cancel
    await p.locator(`[data-ocard="${ids.a}"] [data-cancel="${ids.a}"]`).click(); await p.waitForTimeout(400);
    ok(/including the plates you added/.test(await txt(p, '#sheet')), 'O9', 'whole-order cancel says it includes added plates');
    ok(p.errs.length === 0, 'Ox', 'no page errors', p.errs.join(' | ')); await p.context().close(); }
  await b.close(); })();
