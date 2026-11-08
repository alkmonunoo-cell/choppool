const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 } });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  const step = async (n, f) => { try { await f(); console.log('ok', n); } catch (e) { console.log('FAIL', n, e.message.split('\n')[0]); } };
  await p.clock.install({ time: new Date('2026-11-03T09:00:00Z') });
  await p.addInitScript(() => localStorage.setItem('cp_splash_v','1')); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's1'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s1]').click({ force: true }); await p.waitForTimeout(400);
  const ids = await p.evaluate(async () => { const it = S.items.find(i => i.kitchen_id === 'k1'); const mk = async sp => (await api.placeOrder({ site: 's1', item: it.id, qty: 2, name: 'Ama Owusu', phone: '0240000001', special: sp })).id;
    const a = await mk('Extra shito, no pepper'), c = await mk('Grilled tilapia instead of chicken'); local.set('cp_orders', [{ id: a, order_date: S.date }, { id: c, order_date: S.date }]); return [a, c]; });
  await step('seller sees detail', async () => { await p.evaluate(() => location.hash = '#kitchen-demok1'); await p.waitForTimeout(1000);
    console.log((await p.locator('form.quote').first().innerText()).replace(/\n+/g, ' | ')); await p.screenshot({ path: '/tmp/s_quote.png', fullPage: true });
    const f = p.locator('form.quote', { hasText: 'Extra shito' }); await f.locator('input').fill('70'); await f.locator('button.btn').click(); await p.waitForTimeout(600);
    await p.locator('form.quote', { hasText: 'Grilled tilapia' }).locator('[data-decline]').click(); await p.fill('#decWhy', 'No tilapia today'); await p.click('#decYes'); await p.waitForTimeout(600); console.log('  toast:', await p.locator('#toast').innerText()); });
  await step('customer breakdown', async () => { await p.evaluate(() => location.hash = '#order'); await p.waitForTimeout(1200); await p.click('.tabbar [data-tab=orders]'); await p.waitForTimeout(500);
    for (const t of await p.locator('#tabOrders article').allInnerTexts()) console.log('  ORDER:', t.replace(/\n+/g, ' | ')); await p.screenshot({ path: '/tmp/c_breakdown.png', fullPage: true });
    await p.click('[data-oseg=past]'); await p.waitForTimeout(300); await p.click('[data-reorder]'); await p.waitForTimeout(500); console.log('  reorder sheet open:', await p.locator('#sheetBg.open').count()); });
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
