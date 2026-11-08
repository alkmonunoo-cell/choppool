const { chromium, devices } = require('playwright');
const OUT = '/tmp/da/';
(async () => { const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
  const ctx = await b.newContext({ ...devices['iPhone 14'], colorScheme: scheme });
  await ctx.addInitScript(() => { localStorage.setItem('cp_splash_v','1'); localStorage.setItem('cp_site', JSON.stringify('s1')); });
  const p = await ctx.newPage(); p.setDefaultTimeout(6000); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route(/tile\.openstreetmap|nominatim/, r => r.abort());
  const shot = async (n, full = false) => { await p.addStyleTag({ content: '#demoBar{display:none!important}' }); await p.waitForTimeout(500); await p.screenshot({ path: OUT + scheme + '_' + n + '.png', fullPage: full }); };
  const tap = async sel => { await p.locator(sel).first().click().catch(e => console.log('miss', sel)); await p.waitForTimeout(600); };
  const tab = async name => { await p.locator('.tabbar button', { hasText: name }).click(); await p.waitForTimeout(700); window_scroll = 0; await p.evaluate(() => scrollTo(0, 0)); };
  await p.goto('http://localhost:8765/index.html#order'); await p.waitForSelector('#tabHome'); await p.waitForTimeout(1500);
  await shot('01_home'); await shot('01_home_full', true);
  await tab('Vendors'); await shot('02_vendors', true);
  await p.locator('[aria-label*="List"], .vtoggle button').nth(1).click().catch(()=>{}); await p.waitForTimeout(400); await shot('03_vendors_list');
  await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(800); await shot('04_vendor_page'); await shot('04_vendor_page_full', true);
  await p.locator('#vfoot [data-vgo], #vfoot button').first().click().catch(()=>{}); await p.waitForTimeout(800); await shot('05_order_sheet'); 
  await p.evaluate(() => { const s = document.querySelector('.sheet'); if (s) s.scrollTop = 99999; }); await p.waitForTimeout(300); await shot('05b_order_sheet_bottom');
  // place an order
  await p.fill('#fName', 'Ama Mensah').catch(()=>{}); await p.fill('#fPhone', '0241234567').catch(()=>{}); await p.fill('#fRef', '51234567890').catch(()=>{});
  await p.locator('#submitBtn').click().catch(()=>{}); await p.waitForTimeout(1200); await shot('06_confirmation');
  await p.keyboard.press('Escape'); await p.evaluate(() => { try { closeSheet(); closeVendor(); } catch(e){} }); await p.waitForTimeout(500);
  await tab('Orders'); await shot('07_orders', true);
  await tab('Account'); await shot('08_account', true);
  await tap('#profBtn'); await shot('09_profile'); await p.evaluate(() => closeSheet()); await p.waitForTimeout(400);
  await tap('[data-acc="notif"]'); await shot('10_notifs'); await p.evaluate(() => closeSheet()); await p.waitForTimeout(400);
  await tap('[data-acc="help"]'); await shot('11_help', true); await p.evaluate(() => closeSheet()); await p.waitForTimeout(400);
  await tap('[data-acc="building"]'); await shot('12_building'); await p.evaluate(() => closeSheet()); await p.waitForTimeout(400);
  await tab('Home'); await tap('#bell').catch(()=>{}); await shot('13_updates'); await p.evaluate(() => closeSheet()); await p.waitForTimeout(400);
  await p.locator('.searchbtn, #searchBtn, [aria-label*="Search"]').first().click().catch(()=>{}); await p.waitForTimeout(600); await shot('14_search'); await p.evaluate(() => closeSheet()); await p.waitForTimeout(300);
  for (const [n, h] of [['20_kitchen', '#kitchen-demok1'], ['21_vendor_custadded', '#kitchen-demov1'], ['22_rider', '#rider-demor1'], ['23_host', '#host-demoh1'], ['30_admin', '#admin']]) {
    await p.goto('http://localhost:8765/index.html' + h); await p.waitForTimeout(1800); await shot(n, true);
  }
  // admin tabs
  const tabs = await p.locator('[data-atab]').evaluateAll(els => els.map(e => e.dataset.atab)).catch(() => []);
  for (const t of tabs) { await p.locator(`[data-atab="${t}"]`).first().click(); await p.waitForTimeout(900); await shot('31_admin_' + t, true);
    const subs = await p.locator('#aSub [data-asub]').evaluateAll(els => els.map(e => e.dataset.asub)).catch(() => []);
    for (const s2 of subs.slice(1)) { await p.locator(`#aSub [data-asub="${s2}"]`).click(); await p.waitForTimeout(700); await shot('32_admin_' + t + '_' + s2, true); } }
  console.log(scheme, 'errors', errs.slice(0,5), 'admin tabs', tabs);
  await ctx.close(); }
  await b.close(); })();
