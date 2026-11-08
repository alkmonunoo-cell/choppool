const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 } });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.clock.install({ time: new Date('2026-11-03T17:20:00Z') });
  await p.addInitScript(() => (localStorage.setItem('cp_splash_v','1'), ['cp_intro_done','cp_intro_kitchen','cp_intro_rider','cp_intro_host'].forEach(k => localStorage.setItem(k, 'true')))); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's3'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s3]').click({ force: true }); await p.waitForTimeout(400);
  const r = await p.evaluate(async () => { try { return await api.placeOrder({ site: 's3', item: 'i7', qty: 1, name: 'Ama', phone: '0240000001', ref: 'MOMO1' }); } catch (e) { return 'ERR ' + e.message; } });
  console.log('order', JSON.stringify(r).slice(0, 120));
  await p.evaluate(() => refreshBoard()); await p.waitForTimeout(300); await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300);
  console.log('customer before:', (await p.locator('#kitchensList [data-vendor]').first().innerText()).replace(/\n+/g,' | ').slice(0,90));
  await p.evaluate(() => location.hash = '#kitchen-demov1'); await p.waitForTimeout(1000);
  console.log('SELLER:', (await p.locator('#view').innerText()).slice(0, 300).replace(/\n+/g,' | '));
  await p.screenshot({ path: '/tmp/kday2.png' });
  await p.click('#openDay'); await p.waitForTimeout(500); console.log('toast:', await p.locator('#toast').innerText());
  await p.evaluate(() => location.hash = '#order'); await p.waitForTimeout(1200); await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300);
  console.log('customer after:', (await p.locator('#kitchensList [data-vendor]').first().innerText()).replace(/\n+/g,' | ').slice(0,90));
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
