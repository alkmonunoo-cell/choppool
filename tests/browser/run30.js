// Got my food straight after Delivered (no code check), auto-receive, review prompt next open, profile name switch
const { chromium, devices } = require('playwright');
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['iPhone 14'] });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  await p.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  const ok = (c, m) => console.log(c ? 'ok' : 'FAIL', m);
  await p.goto('http://localhost:8765/index.html'); await p.waitForTimeout(1500);
  const id = await p.evaluate(async () => { await api.kitchenOpenDay('demok1', S.date).catch(() => {});
    const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0240000001', ref: '51234567890' });
    local.set('cp_orders', (local.get('cp_orders') || []).concat({ id: r.id, order_date: r.order_date })); local.set('cp_me', { name: 'Ama Owusu', phone: '0240000001' });
    await api.updateOrder(r.id, { status: 'paid' }); return r.id; });
  const pid = await p.evaluate(async id => (await api.myOrders([id]))[0].pool_id, id);
  // before delivered: no Got my food
  await p.evaluate(() => refreshMine()); await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(500);
  ok(await p.locator(`[data-gotit="${id}"]`).count() === 0, 'no Got my food before Delivered');
  await p.evaluate(async pid => { for (const st of ['accepted', 'ready', 'picked_up', 'delivered']) await api.updatePool(pid, { status: st }); await refreshMine(); renderOrders(); }, pid); await p.waitForTimeout(500);
  const t = await p.locator('#tabOrders').innerText();
  ok(/Your lunch is here/.test(t) && await p.locator(`[data-gotit="${id}"]`).count() === 1, 'Got my food right after Delivered, no code check');
  // auto-receive: push delivered time back 2h+
  await p.evaluate(async pid => { const P = await api.adminData ? null : null; }, pid);
  const auto = await p.evaluate(async (a) => { const [id, pid] = a; await api.updatePool(pid, { delivered_at: new Date(Date.now() - 125 * 6e4).toISOString() }); const o = (await api.myOrders([id]))[0]; return [o.status, !!o.received_at]; }, [id, pid]);
  ok(auto[0] === 'collected' && auto[1], 'auto-received 2 hours after Delivered (' + auto + ')');
  // next open: review prompt once
  console.log('  dbg', await p.evaluate(() => JSON.stringify([local.get('cp_review_asked'), S.reviewAskedThisVisit, S.splashing, document.body.className, (S.mine||[]).map(o => [o.received_at, o.my_rating, o.problem])])));
  await p.evaluate(async () => { closeSheet(); S.reviewAskedThisVisit = false; await refreshMine(); }); await p.waitForTimeout(1500);
  ok(/How was lunch/.test(await p.locator('#sheet').innerText().catch(() => '')), 'review prompt on next open');
  await p.evaluate(async () => { closeSheet(); S.reviewAskedThisVisit = false; await refreshMine(); }); await p.waitForTimeout(1500);
  ok(!(await p.locator('#sheetBg.open').count()), 'review prompt only once');
  // profile name switch
  await p.click('.tabbar [data-tab=wallet]'); await p.waitForTimeout(400); ok(await p.locator('[data-acc=privacy]').count() === 0, 'no separate name privacy row');
  await p.click('#profBtn'); await p.waitForTimeout(300); ok(await p.locator('#pfShow').count() === 1, 'name switch inside Edit profile');
  console.log('errors', errs); await b.close(); })();
