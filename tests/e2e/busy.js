// Sign in / sign up / rider application: spinner while working, no double submits
const { chromium, phone, ok, txt } = require('./h');
(async () => {
  const b = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
    const p = await phone(b, { time: '2026-11-09T09:00:00Z', scheme });
    await p.evaluate(() => { window.__calls = 0; const slow = f => async (...a) => { window.__calls++; await new Promise(r => setTimeout(r, 1200)); return f(...a); };
      api.signIn = slow(api.signIn.bind(api)); api.signUp = slow(api.signUp.bind(api)); api.riderApply = slow(api.riderApply.bind(api)); });
    await p.evaluate(() => openAccount(null, 'signin')); await p.waitForTimeout(500);
    await p.fill('#aEmail', 'ama@example.com'); await p.fill('#aPw', 'secret12'); await p.press('#aPw', 'Enter'); await p.waitForTimeout(250);
    const t = await txt(p, '#authForm [type=submit]'), busy = await p.getAttribute('#authForm [type=submit]', 'aria-busy');
    await p.screenshot({ path: `/tmp/e2e/shots27/busy-${scheme}.png`, clip: { x: 0, y: 380, width: 390, height: 420 } });
    await p.press('#aPw', 'Enter'); await p.press('#aPw', 'Enter'); await p.waitForTimeout(1600);
    ok(/Signing in…/.test(t) && busy === 'true', 'b.1' + scheme, 'sign in shows Signing in… with a spinner', t);
    ok(await p.evaluate(() => window.__calls) === 1, 'b.2' + scheme, 'pressing Enter again does not sign in twice', await p.evaluate(() => window.__calls));
    // rider application
    await p.evaluate(() => { window.__calls = 0; location.hash = '#rider-signup'; }); await p.waitForTimeout(1300);
    for (const [s, v] of [['#rsName', 'Yaw Mensah'], ['#rsPhone', '0244001122'], ['#rsCard', 'GHA-123456789-0'], ['#rsLic', 'DL123456'], ['#rsExp', '2028-06-30']]) await p.fill(s, v).catch(() => {});
    await p.click('#rsForm .btn'); await p.waitForTimeout(200); const rt = await txt(p, '#rsForm .btn');
    await p.click('#rsForm .btn', { force: true }).catch(() => {}); await p.waitForTimeout(1600);
    ok(/Sending application…/.test(rt) && await p.evaluate(() => window.__calls) === 1, 'b.3' + scheme, 'rider sign-up shows progress and sends once', rt);
    ok(p.errs.length === 0, 'b.x' + scheme, 'no page errors', p.errs.join(' | '));
    await p.context().close();
  }
  await b.close();
})();
