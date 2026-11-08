const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 }, permissions: ['clipboard-read', 'clipboard-write'] });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  const step = async (n, f) => { try { await f(); console.log('ok', n); } catch (e) { console.log('FAIL', n, e.message.split('\n')[0]); } };
  await p.clock.install({ time: new Date('2026-11-04T08:00:00Z') });
  await p.addInitScript(() => localStorage.setItem('cp_splash_v','1')); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's1'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s1]').click({ force: true }); await p.waitForTimeout(300);
  await step('hero best delivery', async () => { console.log('  ', (await p.locator('.hero-stats').innerText()).replace(/\n+/g, ' | ')); });
  await step('order + share from confirmation', async () => {
    await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300); await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(500); await p.locator('#vfoot [data-vgo]').click(); await p.waitForTimeout(400);
    await p.fill('#fName', 'Ama Owusu').catch(() => {}); await p.fill('#fPhone', '0240000001').catch(() => {}); await p.fill('#fRef', '51234567890').catch(() => {});
    await p.click('#submitBtn'); await p.waitForTimeout(800);
    console.log('  sheet:', (await p.locator('#sheet').innerText()).replace(/\n+/g, ' | ').slice(0, 300));
    await p.click('#sharePool'); await p.waitForTimeout(500); console.log('  toast:', await p.locator('#toast').innerText()); console.log('  clip:', await p.evaluate(() => navigator.clipboard.readText()));
  });
  await step('order card share', async () => { await p.click('#toOrders').catch(() => {}); await p.waitForTimeout(400); console.log('  share buttons:', await p.locator('[data-share]').count()); });
  await step('join link opens pool', async () => {
    const link = await p.evaluate(() => navigator.clipboard.readText()); const hash = link.slice(link.indexOf('#'));
    const p2 = await ctx.newPage(); await p2.clock.install({ time: new Date('2026-11-04T08:05:00Z') });
    await p2.addInitScript(() => localStorage.setItem('cp_splash_v','1')); await p2.goto('file:///home/claude/choppool/index.html' + hash); await p2.waitForTimeout(1800);
    console.log('  hash now:', await p2.evaluate(() => location.hash), '| building:', await p2.locator('#placeName').innerText(), '| sheet:', (await p2.locator('#sheet').innerText()).slice(0, 80).replace(/\n+/g, ' | '));
  });
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
