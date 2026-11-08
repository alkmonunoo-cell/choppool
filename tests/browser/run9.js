const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 400, height: 860 }, deviceScaleFactor: 2, geolocation: { latitude: 5.5645, longitude: -0.2005 }, permissions: ['geolocation'] });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  const step = async (n, f) => { try { await f(); console.log('ok', n); } catch (e) { console.log('FAIL', n, e.message.split('\n')[0]); } };
  await p.addInitScript(() => localStorage.setItem('cp_splash_v','1')); await p.goto('file:///home/claude/choppool/index.html'); await p.waitForTimeout(1500);
  await step('pick heritage', async () => { await p.evaluate(v => { if (!document.getElementById('sheetBg').classList.contains('open') || !document.querySelector('#sheet #siteList')) openSitePicker(); const q = document.getElementById('fbQ'); if (q && !document.querySelector('#siteList input[value=' + v + ']')) { q.value = S.sites.find(x => x.id === v).name; q.dispatchEvent(new Event('input')); } }, 's1'); await p.waitForTimeout(500); await p.locator('#siteList input[value=s1]').click({ force: true }); await p.waitForTimeout(400); });
  await step('home', async () => { console.log('  greeting:', (await p.locator('#hero p').first().innerText())); console.log('  active pools:', await p.locator('#pools .prow').count(), ); await p.screenshot({ path: '/tmp/c_home.png' }); });
  await step('kitchens tab', async () => { await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(400); console.log('  kitchens:', await p.locator('#kitchensList [data-vendor]').count(), '|', await p.locator('#kitchensSub').innerText()); await p.screenshot({ path: '/tmp/c_kitchens.png' }); });
  await step('sign up with name', async () => { await p.click('.tabbar [data-tab=wallet]'); await p.waitForTimeout(500); await p.click('#wSign'); await p.fill('#aName','Albert Nunoo'); await p.fill('#aEmail','albert@x.com'); await p.fill('#aPw','secret1'); await p.click('#authForm button[type=submit]'); await p.waitForTimeout(500); await p.click('.tabbar [data-tab=home]'); await p.waitForTimeout(300); console.log('  greeting:', await p.locator('#hero p').first().innerText()); });
  await step('dark', async () => { await p.emulateMedia({ colorScheme: 'dark' }); await p.waitForTimeout(300); await p.screenshot({ path: '/tmp/c_dark.png' }); await p.emulateMedia({ colorScheme: 'light' }); });
  await step('admin edit kitchen name', async () => { await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(800); await p.click('[data-atab=menus]'); await p.waitForTimeout(400);
    const c = p.locator('[data-kitchen]').first(); await c.locator('summary').click(); await c.locator('[data-f=public_name]').fill('Ghana classics'); await c.locator('[data-act=kitchen-save]').click(); await p.waitForTimeout(500); console.log('  toast:', await p.locator('#toast').innerText()); });
  await step('customer sees renamed', async () => { await p.evaluate(() => location.hash = '#order'); await p.waitForTimeout(800); await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300); console.log('  first kitchen:', await p.locator('#kitchensList [data-vendor] strong').first().innerText()); });
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
