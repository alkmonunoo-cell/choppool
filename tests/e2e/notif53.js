const { chromium, phone, ok, txt } = require('./h');
const T = '2026-11-24T08:30:00Z';
(async () => { const b = await chromium.launch();
for (const scheme of ['light', 'dark']) {
  const p = await phone(b, { time: T, scheme, me: { name: 'Ama Mensah', phone: '0244111222' } });
  await p.evaluate(() => { window.__noSim = true; window.__notes = 0; window.Notification = function () { window.__notes++; }; window.Notification.permission = 'granted'; });
  await p.evaluate(async () => { await api.signUp('ama@test.com', 'secret12', 'Ama'); await api.verifyCode('ama@test.com', '123456'); await refreshUser();
    await api.updateSettings({ pay_mode: 'paystack', paystack_fee_from: '2026-11-24' }); Object.assign(S, await api.load()); local.set('cp_alerts', true); });
  const openCheckout = async () => {
    await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(400); await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(800);
    await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300);
    await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(600); };
  await openCheckout();
  ok(/1\.95% payment fee \(about GHS \d+\.\d\d\) is added on the next screen/.test(await txt(p, '#payTo')), 'n1', scheme + ' checkout says the 1.95% fee is added', await txt(p, '#payTo'));
  await p.screenshot({ path: `/tmp/n53-checkout-${scheme}.png` });
  // Place and close the Paystack window without paying: pool hidden, no activity
  await p.click('#submitBtn'); await p.waitForSelector('.psdemo', { timeout: 5000 }); await p.click('.psdemo [data-ps=cancelled]'); await p.waitForTimeout(1500);
  const h = await p.evaluate(async () => { const o = S.mine[0]; await refreshBoard(); const pl = S.board.pools.find(x => x.id === o.pool_id); return { st: o.status, onBoard: !!pl, meals: pl ? pl.meals : 0, act: S.board.activity.some(a => a.id === o.id) }; });
  ok(h.st === 'pending' && !h.onBoard && !h.act, 'n2', scheme + ' unpaid: pool hidden, my order not announced', JSON.stringify(h));
  // Pay now: pool shows, tagged Started by you, no alert about my own order
  await p.click('#tabOrders [data-paynow]'); await p.waitForSelector('.psdemo'); await p.click('.psdemo [data-ps=success]'); await p.waitForTimeout(1800);
  await p.evaluate(() => closeSheet && closeSheet());
  const toasts = []; await p.exposeFunction('__t', m => toasts.push(m)).catch(() => {});
  await p.evaluate(() => { const o = window.toast; window.toast = m => { window.__t(String(m)); return o(m); }; });
  await p.evaluate(async () => { await refreshMine(); await refreshBoard(); await new Promise(r => setTimeout(r, 300)); });
  const v = await p.evaluate(() => { const o = S.mine.find(x => !x.parent_id); const pl = S.board.pools.find(x => x.id === o.pool_id); return { onBoard: !!pl, started: pl && iStarted(pl), act: S.board.activity.filter(a => a.pool_id === o.pool_id).length }; });
  ok(v.onBoard && v.act === 1, 'n3', scheme + ' paid: pool live and my order counts', JSON.stringify(v));
  ok(!toasts.some(m => /just ordered/.test(m)), 'n4', scheme + ' no "someone just ordered" about my own order', toasts.join(' | '));
  await p.click('.tabbar [data-tab=home]'); await p.waitForTimeout(600);
  const st = await p.evaluate(() => { const o = S.mine.find(x => !x.parent_id); const pl = S.board.pools.find(x => x.id === o.pool_id); return iStarted(pl); });
  ok(/Started by you/.test(await txt(p, '#pools')) === st, 'n5', scheme + ' Home shows Started by you', (await txt(p, '#pools')).slice(0, 160));
  await p.screenshot({ path: `/tmp/n53-home-${scheme}.png` });
  // Someone else at the building pays: alert names the vendor; no phone banner while the app is on screen
  const vendor = await p.evaluate(async () => { await api.updateSettings({ pay_mode: 'manual' }); Object.assign(S, await api.load()); const kid = S.mine.find(x => !x.parent_id).kitchen_id;
    await api.signOut(); const it = MENU.raw.find(i => i.kitchen_id === kid); await api.placeOrder({ site: S.siteId, item: it.id, qty: 1, name: 'Kofi', phone: '0244999888', ref: 'MP99887766' });
    await api.signIn('ama@test.com', 'secret12'); await refreshUser(); return menuOf(kid).public_name; });
  await p.evaluate(async () => { await refreshBoard(); await new Promise(r => setTimeout(r, 400)); });
  const alert = toasts.find(m => /just ordered from/.test(m) && m.includes('Kofi') === false) || toasts.filter(m => /just ordered/.test(m)).join(' | ');
  ok(alert.includes('just ordered from ' + vendor), 'n6', scheme + ' someone else: alert names the vendor', alert);
  ok(await p.evaluate(() => window.__notes) === 0, 'n7', scheme + ' no phone banner while the app is open');
  // Cancel my own order: no alert about it
  const before = toasts.length;
  await p.evaluate(async () => { const o = S.mine.find(x => !x.parent_id); await api.cancelOrder(o.id, 'You cancelled (Changed my plans)', 'wallet'); await refreshMine(); });
  ok(!toasts.slice(before).some(m => /You cancelled/.test(m)) && await p.evaluate(() => window.__notes) === 0, 'n8', scheme + ' my own cancel: no alert', toasts.slice(before).join(' | '));
  // Admin: Settings › Payments has the date
  await p.evaluate(() => { location.hash = '#admin'; }); await p.waitForTimeout(1500);
  await p.evaluate(() => { const t = [...document.querySelectorAll('[data-atab]')].find(x => /Settings/.test(x.textContent)); t && t.click(); }); await p.waitForTimeout(1000);
  ok(await p.locator('#stPsFee').count() === 1 && await p.locator('#stPsFee').inputValue() === '2026-11-24', 'n9', scheme + ' Settings › Payments shows the fee date');
  await p.locator('#stPsFee').scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `/tmp/n53-settings-${scheme}.png` });
  ok(!p.errs.length, 'n10', scheme + ' no page errors', p.errs.join(' | '));
  await p.close();
}
await b.close(); })();
