const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await (await b.newContext({ viewport: { width: 400, height: 860 } })).newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.clock.install({ time: new Date('2026-11-03T08:00:00Z') });
  await p.addInitScript(() => localStorage.setItem('cp_splash_v','1')); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's1'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s1]').click({ force: true }); await p.waitForTimeout(300);
  const id = await p.evaluate(async () => { const it = S.items.find(i => i.kitchen_id === 'k1'); const a = await api.placeOrder({ site: 's1', item: it.id, qty: 1, name: 'Esi Boateng', phone: '0240000003', ref: '51234567890' }); for (let n = 0; n < 3; n++) await api.placeOrder({ site: 's1', item: it.id, qty: 3, name: 'Kofi Mensah', phone: '0240000002', ref: '5123456780' + n }); local.set('cp_orders', [{ id: a.id, order_date: S.date }]); await api.updateOrder(a.id, { status: 'paid' }); return a.id; });
  await p.clock.setFixedTime(new Date('2026-11-03T11:00:00Z')); await p.evaluate(() => refreshMine()); await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(500);
  console.log('GUEST:', (await p.locator('#tabOrders article').first().innerText()).replace(/\n+/g, ' | '));
  await p.click('[data-keepcb]'); await p.waitForTimeout(300); await p.fill('#aName', 'Esi Boateng'); await p.fill('#aEmail', 'esi@x.com'); await p.fill('#aPw', 'secret1'); await p.click('#authForm button[type=submit]'); await p.waitForTimeout(700);
  await p.click('.tabbar [data-tab=wallet]'); await p.waitForTimeout(500); console.log('WALLET:', (await p.locator('#tabWallet').innerText()).slice(0, 160).replace(/\n+/g, ' | '));
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
