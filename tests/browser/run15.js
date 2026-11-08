const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 } });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.clock.install({ time: new Date('2026-11-03T09:00:00Z') });
  await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's1'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s1]').click({ force: true }); await p.waitForTimeout(300);
  await p.locator('#pools [data-menu]').first().click(); await p.waitForTimeout(500);
  console.log('SUM:', (await p.locator('#sum').innerText()).replace(/\n+/g, ' | '), '| total', await p.locator('#totTxt').innerText());
  await p.screenshot({ path: '/tmp/o_sheet.png' });
  const r = await p.evaluate(async () => { const it = S.items.find(i => i.kitchen_id === 'k1'); const o = await api.placeOrder({ site: 's1', item: it.id, qty: 1, name: 'Ama Owusu', phone: '0240000001', ref: 'MOMO9' }); return (await api.myOrders([o.id]))[0]; });
  console.log('charged delivery per meal:', r.max_fee, 'amount due', r.amount_due);
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
