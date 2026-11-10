const { chromium, phone } = require('./h');
(async () => { const b = await chromium.launch(); const p = await phone(b, { time: '2026-11-09T09:00:00Z', viewport: { width: 390, height: 844 } }); await p.waitForTimeout(800);
  for (const m of ['Updated', 'Thanks. We\'ll check the payment again.', 'The vendor isn\'t cooking today. GHS 45.00 is back in your wallet, ready for your next order.']) {
    await p.evaluate(m => toast(m), m); const t0 = Date.now(); while (await p.evaluate(() => $('#toast').classList.contains('show'))) await p.waitForTimeout(100); console.log(((Date.now() - t0) / 1000).toFixed(1) + 's', m.length, 'chars'); }
  await p.evaluate(() => toast('Tap me away')); await p.click('#toast'); console.log('tap dismiss', !(await p.evaluate(() => $('#toast').classList.contains('show'))));
  await b.close(); })();
