// Update 27: tester feedback fixes
const fs = require('fs');
const { chromium, results, setArea, ok, note, phone, txt } = require('./h');
const go = async (p, h, w = 1300) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
const tab = async (p, t, s) => { await p.evaluate(t => document.querySelector(`[data-atab="${t}"]`)?.click(), t); await p.waitForTimeout(600); if (s) { await p.evaluate(s => document.querySelector(`[data-asub="${s}"]`)?.click(), s); await p.waitForTimeout(600); } };
const src = fs.readFileSync('/home/claude/choppool/index.html', 'utf8');
(async () => {
  const b = await chromium.launch();
  setArea('27. Tester feedback');
  ok(/\["#email", "#pw", "#aname"\]\.forEach\(sel => \$\(sel\)\?\.addEventListener\("keydown", e => \{ if \(e\.key === "Enter"\)/.test(src), '27.01', 'Enter signs in on the team login');

  // Customer: two orders (one with 3 meals), badge counts meals
  let p = await phone(b, { time: '2026-11-09T09:00:00Z', me: { name: 'Ama', phone: '0244111222' } });
  const r = await p.evaluate(async () => {
    const a = await api.placeOrder({ site: 's1', item: 'i1', qty: 3, name: 'Ama', phone: '0244111222', ref: '5123456781' });
    const ids = (local.get('cp_orders') || []); ids.push({ id: a.id, order_date: a.order_date }); local.set('cp_orders', ids);
    await refreshMine(); return a;
  });
  await p.waitForTimeout(600);
  const badge = await p.evaluate(() => (document.querySelector('.tabbar [data-tab=orders] .badge, .tabbar [data-tab=orders] .tbadge, .tabbar [data-tab=orders] [class*=badge]') || {}).textContent || '');
  ok(badge.trim() === '3', '27.02', 'Orders badge counts meals, not vendors', badge);

  // Bell: a notification received while push is off lands under the bell
  await p.evaluate(() => sysNotify('Payment confirmed · code Z-11', 'Your order is paid.'));
  await p.waitForTimeout(300);
  const dot = await p.evaluate(() => !document.querySelector('#bellDot').classList.contains('hidden'));
  await p.click('#bell'); await p.waitForTimeout(600);
  const inbox = await txt(p, '#sheet');
  ok(dot && /Payment confirmed · code Z-11/.test(inbox), '27.03', 'received notification shows under the bell', inbox.slice(0, 160));
  await p.evaluate(() => closeSheet());

  // Rider sign-up checks the Ghana Card, licence and expiry
  const rv = await p.evaluate(async () => { const out = [];
    for (const x of [{ card: '123', licence: 'DL12345', expiry: '2028-01-01' }, { card: 'GHA-123456789-0', licence: 'D1', expiry: '2028-01-01' }, { card: 'GHA-123456789-0', licence: 'DL12345', expiry: '2020-01-01' }])
      try { await api.riderApply({ name: 'Yaw Mensah', phone: '0244001122', ...x }); out.push('accepted'); } catch (e) { out.push(e.message); }
    return out; });
  ok(/Ghana Card/.test(rv[0]) && /licence number/.test(rv[1]) && /expired/.test(rv[2]), '27.04', 'rider sign-up rejects bad card, licence and expiry', rv.join(' / '));
  await go(p, '#rider-signup', 1300);
  const rl = await txt(p, '#view');
  ok(/Phone number/.test(rl) && await p.locator('#rsCard').count() && await p.locator('#rsLic').count() && await p.locator('#rsExp').count(), '27.05', 'rider form has card, licence, expiry and "Phone number"');

  // Building requested by a customer is live straight away
  const bs = await p.evaluate(async () => { const x = await api.requestSite({ name: 'Volta Place Annex', drop_point: 'Front desk', lat: 5.61, lng: -0.19 }); return x.status || (S.sites.find(s => s.name === 'Volta Place Annex') || {}).status; });
  ok(bs === 'active', '27.06', 'new building is live at once', bs);
  await p.context().close();

  // Team: review header, money tiles, duplicates, fee tile, quiet refresh
  p = await phone(b, { time: '2026-11-09T09:00:00Z' }); p.on('dialog', d => d.accept());
  await go(p, '#admin', 2000);
  const dash = await txt(p, '#view');
  ok(['Received', 'Owed to vendors', 'Owed to delivery', 'Your profit'].every(w => dash.includes(w)), '27.07', 'dashboard shows received, owed to vendors, owed to delivery, profit');
  await tab(p, 'buildings', 'requests');
  const bq = await txt(p, '#view');
  ok(/New & duplicates/.test(bq), '27.08', 'buildings: New & duplicates view', bq.slice(0, 160));
  const subs = await p.$$eval('[data-asub]', x => x.map(b => b.dataset.asub + ':' + b.textContent.trim()));
  await tab(p, 'menus', 'reviews'); await p.waitForTimeout(800);
  const revOk = await p.$$eval('#revAdmin p.small[style*="700"]', x => x.map(e => e.textContent)).then(x => x[0]).catch(() => null);
  if (revOk) ok(/·/.test(revOk), '27.10', 'ratings show vendor and meal', revOk); else note('No demo reviews to check the header against');
  note('Review header sample: ' + revOk);
  // quiet refresh with no change keeps the same nodes (no flicker)
  await tab(p, 'today');
  const same = await p.evaluate(async () => { const n = document.querySelector('#aBody').firstElementChild; await adminRefresh(false); await new Promise(r => setTimeout(r, 400)); return document.querySelector('#aBody').firstElementChild === n; });
  ok(same, '27.09', 'auto refresh with nothing new does not redraw');
  // vendor fee: a vendor who hasn't accepted the new fee sees automatic days paused, and the team sees them listed
  const fee = await p.evaluate(async () => { const out = {};
    const k = (S.admin.kitchens || []).find(x => x.active && !x.archived && x.token);
    await api.updateSettings({ vendor_fee_rate: 0.05 }).catch(e => out.err = e.message);
    out.token = k && k.token; return out; });
  await go(p, '#admin', 1500); await tab(p, 'today');
  note('Fee raise: ' + JSON.stringify(fee));
  if (fee.token) { await go(p, '#kitchen-' + fee.token, 1800); const kv = await txt(p, '#view');
    ok(/accept/i.test(kv) && /fee/i.test(kv), '27.11', 'vendor is asked to accept the new fee', kv.slice(0, 200)); }
  ok(p.errs.length === 0, '27.x', 'no page errors', p.errs.join(' | '));
  await p.context().close();
  await b.close();
  fs.writeFileSync('/tmp/e2e/res-u27.json', JSON.stringify(results, null, 1));
})();
