const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme });
  await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(1500);
  await p.evaluate(() => { S.recovery = true; S.recoveryTeam = true; showRecovery(); }); await p.waitForTimeout(700);
  const v = await txt(p, '#view');
  if (scheme === 'light') { ok(/Choose a new password/.test(v) && !(await p.locator('[data-atab]').count()), 'n.1', 'reset link shows only the new-password page', v.slice(0, 120));
    await p.evaluate(() => location.hash = '#order'); await p.waitForTimeout(800);
    ok(/Choose a new password/.test(await txt(p, '#view')) && !(await p.locator('.tabbar').count()), 'n.2', 'other pages are blocked until it is saved');
    await p.fill('#npPw', 'secret12'); await p.fill('#npPw2', 'secret13'); await p.click('#npForm .btn'); await p.waitForTimeout(300);
    ok(/don't match/.test(await txt(p, '#npErr')), 'n.3', 'passwords must match');
    await p.fill('#npPw2', 'secret12'); await p.click('#npForm .btn'); await p.waitForTimeout(1500);
    ok(!/Choose a new password/.test(await txt(p, '#view')) && await p.evaluate(() => location.hash) === '#admin', 'n.4', 'after saving, the team screen opens', await p.evaluate(() => location.hash)); }
  else await p.screenshot({ path: '/tmp/e2e/shots27/recov-dark.png' });
  console.log(scheme, p.errs); await p.context().close(); }
  await b.close(); })();
