const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 } });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.clock.install({ time: new Date('2026-11-03T17:20:00Z') });
  await p.addInitScript(() => (localStorage.setItem('cp_splash_v','1'), ['cp_intro_done','cp_intro_kitchen','cp_intro_rider','cp_intro_host'].forEach(k => localStorage.setItem(k, 'true')))); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's3'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s3]').click({ force: true }); await p.waitForTimeout(300);
  await p.evaluate(async () => api.placeOrder({ site: 's3', item: 'i7', qty: 1, name: 'Ama Owusu', phone: '0240000001', ref: 'MOMO1' }));
  await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(1500);
  console.log('DAYS:', await p.locator('#aDays').innerText(), '| date', await p.locator('#aDate').inputValue());
  console.log('POOLS:', (await p.locator('#aBody').innerText()).slice(0, 500).replace(/\n+/g, ' | '));
  await p.click('[data-aday="2026-11-03"]'); await p.waitForTimeout(800);
  console.log('TODAY DAYS:', await p.locator('#aDays').innerText()); await p.click('[data-atab=today]'); await p.waitForTimeout(600); console.log('FLAGS:', (await p.locator('.flags').innerText().catch(() => 'none')).replace(/\n+/g, ' | '));
  await p.screenshot({ path: '/tmp/a_days.png' });
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
