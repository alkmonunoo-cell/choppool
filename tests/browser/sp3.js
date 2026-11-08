const { chromium, devices } = require('playwright');
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['Pixel 7'] });
  await ctx.addInitScript(() => { const m = window.matchMedia.bind(window); window.matchMedia = q => q.includes('standalone') ? { matches: true, addEventListener(){}, removeEventListener(){} } : m(q); });
  const p = await ctx.newPage(); p.on('pageerror', e => console.log('ERR', e.message)); await p.route(/tile\.openstreetmap|cdnjs|nominatim/, r => r.abort());
  const U='http://localhost:8765/index.html'; const t0=Date.now();
  await p.goto(U);
  for (const t of [150, 450, 700, 1100, 1600]) { await p.waitForTimeout(t - (Date.now()-t0)); await p.screenshot({path:`/tmp/b_${t}.png`}); }
  await p.waitForFunction(() => !document.querySelector('.splash'), null, {timeout: 8000}); console.log('splash gone at', Date.now()-t0, 'ms');
  console.log('home built:', await p.locator('#tabHome').count());
  await p.reload(); await p.waitForTimeout(100); console.log('reload:', await p.locator('.splash').count());
  await b.close(); })();
