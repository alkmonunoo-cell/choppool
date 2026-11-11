// Full lunch day across every role, all in one demo page (shared demo data), driven by clicks where a person would click
const { chromium, results, setArea, ok, note, phone, txt, hideToast } = require('./h');
const go = async (p, h, w = 1300) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
const view = p => txt(p, '#view');
const tick = async (p, iso) => { await p.clock.setSystemTime(new Date(iso)); await p.waitForTimeout(200); };
(async () => {
  const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T07:30:00Z' });
  p.on('dialog', d => d.accept());

  setArea('4. Vendor: confirm the day');
  // Ama orders 2 plates from Local favourites through the app
  await p.evaluate(() => setTab('vendors')); await p.waitForTimeout(500);
  await p.evaluate(async () => { await api.kitchenPause('demok1', opsDate(), true); await api.kitchenPause('demok1', opsDate(), false); await refreshBoard().catch(() => {}); });   // start with the vendor not yet confirmed
  await p.evaluate(() => openVendor('k1')); await p.waitForTimeout(800);
  ok(/Confirm|waiting|confirm/i.test(await txt(p, '#vpBanner')), '4.00', 'vendor not confirmed yet: banner says so', await txt(p, '#vpBanner'));
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400);
  await p.click('#dPlus'); await p.click('#dAdd'); await p.waitForTimeout(300);
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(700);
  await p.fill('#fName', 'Ama Owusu'); await p.fill('#fPhone', '0241112223');
  await p.fill('#fRef', '51234567890'); await p.click('#submitBtn'); await p.waitForTimeout(1300);
  const ama = await p.evaluate(() => (S.mine || []).find(o => !o.parent_id));
  ok(ama && ama.status === 'pending' && ama.qty === 2, '4.01', 'Ama placed 2 plates, waiting for payment check', ama && ama.status + ' qty ' + ama.qty);
  await p.evaluate(() => { closeSheet(); closeVendor(true); });
  // Kofi and Esi order too (other phones) – kept on this phone's list so we can look at them
  const others = await p.evaluate(async () => {
    const k = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Kofi Boateng', phone: '0201234567', ref: '52223334445' });
    const e = await api.placeOrder({ site: 's1', item: 'i2', qty: 1, name: 'Esi Mensah', phone: '0551234567', ref: '53334445556' });
    return { kofi: k, esi: e };
  });
  ok(others.kofi.id && others.esi.id, '4.02', 'two more customers ordered');

  await go(p, '#kitchen-demok1');
  let v = await view(p);
  ok(/Customers are waiting for you/.test(v), '4.03', 'vendor sees customers waiting', v.slice(0, 260));
  ok(/8:30|08:30/.test(v), '4.04', 'vendor sees the 8:30 confirm time');
  ok(await p.locator('#openDay').count() === 1, '4.05', '"Yes, I\'m cooking" button');
  note('Vendor screen while customers wait: ' + v.slice(0, 400));
  const canSayNo = await p.locator('#cookCard').innerText().catch(() => '');
  note('Can the vendor say "not cooking today" while customers wait? ' + (/Not cooking|can't cook|Pause/i.test(canSayNo) ? 'yes' : 'NO (only "Yes, I\'m cooking"; customers wait until 8:30)'));
  await p.click('#openDay'); await p.waitForTimeout(1000);
  v = await view(p);
  ok(!/Customers are waiting for you/.test(v), '4.06', 'after confirming, waiting card goes', v.slice(0, 200));

  setArea('5. Admin: check payments');
  await go(p, '#admin', 2000);
  v = await view(p);
  ok(/Ama Owusu/.test(v) || await p.locator('[data-atab]').count() > 0, '5.00', 'admin opens', v.slice(0, 200));
  // go to orders list for today
  const tabs = await p.$$eval('[data-atab]', x => x.map(b => b.dataset.atab + ':' + b.innerText.trim()));
  note('Admin tabs: ' + tabs.join(', '));
  await p.evaluate(() => { const b = document.querySelector('[data-atab="today"]'); b && b.click(); }); await p.waitForTimeout(800);
  const subs = await p.$$eval('[data-asub]', x => x.map(b => b.dataset.asub + ':' + b.innerText.trim().replace(/\s+/g, ' ')));
  note('Today sub-tabs: ' + subs.join(', '));
  await p.evaluate(() => { const b = document.querySelector('[data-asub="orders"]'); b && b.click(); }); await p.waitForTimeout(800);
  v = await view(p);
  ok(/Ama Owusu/.test(v) && /Kofi Boateng/.test(v) && /Esi Mensah/.test(v), '5.01', 'all 3 orders listed for the team');
  ok(await p.locator(".pdotx").count() >= 2, "5.02", 'payments to check are flagged');
  // Ama: mark paid with the status picker
  const sel = p.locator(`select[data-order="${ama.id}"]`);
  if (await sel.count()) { await sel.selectOption('paid'); await p.waitForTimeout(900); }
  else { const row = p.locator(`[data-orow="${ama.id}"]`); note('No status picker on the row; row text: ' + (await row.innerText().catch(() => '-')).replace(/\s+/g, ' ').slice(0, 300)); }
  let st = await p.evaluate(async id => (await api.myOrders([id]))[0].status, ama.id);
  ok(st === 'paid', '5.03', 'team marks Ama paid', st);
  // Kofi: payment not found
  const issueBtn = p.locator(`[data-orow="${others.kofi.id}"] [data-act="pay-issue"]`);
  if (!(await issueBtn.count())) await p.locator(`[data-orow="${others.kofi.id}"]`).click().catch(() => {});
  await p.waitForTimeout(400);
  const ib = p.locator(`[data-act="pay-issue"]`);
  ok(await ib.count() > 0, '5.04', '"Not found / short" button reachable');
  if (await ib.count()) { await p.locator(`[data-orow="${others.kofi.id}"] [data-act="pay-issue"]`).first().click().catch(async () => { await ib.first().click(); }); await p.waitForTimeout(500);
    await p.click('#piGo'); await p.waitForTimeout(900); }
  const kofi1 = await p.evaluate(async id => (await api.myOrders([id]))[0], others.kofi.id);
  ok(kofi1.pay_issue === 'not_found', '5.05', 'Kofi told payment not found', kofi1.pay_issue);
  // Esi: short payment
  await p.locator(`[data-orow="${others.esi.id}"] [data-act="pay-issue"]`).first().click().catch(() => {}); await p.waitForTimeout(500);
  if (await p.locator('#piGo').count()) { await p.check('[name=pi][value=short]'); await p.fill('#piAmt', '20'); await p.click('#piGo'); await p.waitForTimeout(900); }
  const esi1 = await p.evaluate(async id => (await api.myOrders([id]))[0], others.esi.id);
  ok(esi1.pay_issue === 'short', '5.06', 'Esi told payment short', esi1.pay_issue + ' ' + esi1.amount_received);

  setArea('6. Customer sees payment results');
  await p.evaluate(o => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: o.kofi.id, order_date: o.kofi.order_date }, { id: o.esi.id, order_date: o.esi.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); }, others);
  await go(p, '#order', 1500); await p.evaluate(() => refreshMine()); await p.waitForTimeout(800);
  const home = await txt(p, '#tabHome');
  ok(/payment|Payment/.test(home) && await p.locator('.mylunch.bad').count() === 2, '6.01', 'red payment strip on Home', home.slice(0, 300));
  await p.evaluate(() => setTab('orders')); await p.waitForTimeout(700);
  let ot = await txt(p, '#tabOrders');
  ok(/couldn't find your payment/i.test(ot), '6.02', 'order card: payment not found + fix');
  ok(/payment was short/i.test(ot), '6.03', 'order card: payment short + pay the rest');
  // Kofi fixes the reference
  const fx = p.locator(`[data-fixpay="${others.kofi.id}"][data-mode=ref]`);
  if (await fx.count()) { await fx.click(); await p.waitForTimeout(500); const inp = p.locator('#sheet input').first(); await inp.fill('59998887776'); if (await p.locator('#fxPhone').count()) await p.fill('#fxPhone', '0201234567'); await p.locator('#sheet .btn').last().click(); await p.waitForTimeout(900); }
  const kofi2 = await p.evaluate(async id => (await api.myOrders([id]))[0], others.kofi.id);
  ok(!kofi2.pay_issue && kofi2.momo_ref === '59998887776', '6.04', 'Kofi sends new transaction ID, back to checking', JSON.stringify({ i: kofi2.pay_issue, r: kofi2.momo_ref }));
  // Admin finds Kofi's payment
  await go(p, '#admin', 1800); await p.evaluate(() => { document.querySelector('[data-atab="today"]')?.click(); }); await p.waitForTimeout(500); await p.evaluate(() => { document.querySelector('[data-asub="orders"]')?.click(); }); await p.waitForTimeout(700);
  const ks = p.locator(`select[data-order="${others.kofi.id}"]`); if (await ks.count()) { await ks.selectOption('paid'); await p.waitForTimeout(800); }
  st = await p.evaluate(async id => (await api.myOrders([id]))[0].status, others.kofi.id); ok(st === 'paid', '6.05', 'Kofi now paid', st);

  // Kofi's phone is a different phone: take his order off this phone's list again
  await p.evaluate(id => { localStorage.setItem('cp_orders', JSON.stringify(JSON.parse(localStorage.getItem('cp_orders') || '[]').filter(o => o.id !== id))); }, others.kofi.id);
  setArea('7. Cut-off and cooking');
  await tick(p, '2026-11-09T10:31:00Z');
  await go(p, '#kitchen-demok1', 1500); v = await view(p);
  note('Vendor at 10:31: ' + v.slice(0, 500));
  const fb = p.locator('button[data-k="accepted"]'); ok(await fb.count() > 0, '7.01', '"Confirm final batch" after cut-off');
  const esiNow = await p.evaluate(async id => (await api.myOrders([id]))[0], others.esi.id);
  ok(esiNow.status === 'cancelled' && esiNow.cancel_reason === 'Payment not received', '7.02', 'short payment cancelled at cut-off', esiNow.status + ' / ' + esiNow.cancel_reason + ' refund_due ' + esiNow.refund_due);
  ok(!/Esi/.test(v), '7.03', 'cancelled order not on vendor list');
  if (await fb.count()) { await fb.first().click(); await p.waitForTimeout(900); }
  v = await view(p); ok(await p.locator('button[data-k="ready"]').count() > 0, '7.04', '"Food is ready" next');
  note('Vendor cooking list: ' + v.slice(0, 600));
  await p.locator('button[data-k="ready"]').first().click(); await p.waitForTimeout(600);
  if (await p.locator('#rdyYes').count()) { ok(/not ticked/.test(await txt(p, '#sheet')), '7.05', 'asks before Food ready with unticked packs'); await p.click('#rdyYes'); await p.waitForTimeout(900); }

  setArea('8. Rider');
  // Team assigns the rider on Today > Pools
  await go(p, '#admin', 1800); await p.evaluate(() => { document.querySelector('[data-atab="today"]')?.click(); }); await p.waitForTimeout(500); await p.evaluate(() => { document.querySelector('[data-asub="pools"]')?.click(); }); await p.waitForTimeout(700);
  const pc = p.locator(`[data-pool="${ama.pool_id}"]`);
  console.log('DBG', (await view(p)).slice(200, 900), ' ids ' + (await p.$$eval('[data-pool]', x => x.map(e => e.dataset.pool).join(','))) + ' want ' + ama.pool_id); ok(await pc.count() === 1, '8.00', 'team sees the pool card', ' ids ' + (await p.$$eval('[data-pool]', x => x.map(e => e.dataset.pool).join(','))) + ' want ' + ama.pool_id);
  await pc.locator('[data-f=rider_id]').selectOption('r1'); await pc.locator('[data-f=trip_cost]').fill('55'); await pc.locator('[data-act=pool-save]').click(); await p.waitForTimeout(900);
  await tick(p, '2026-11-09T11:45:00Z');
  await go(p, '#rider-demor1', 1500); v = await view(p);
  note('Rider screen: ' + v.slice(0, 500));
  let steps = [];
  for (let i = 0; i < 5; i++) { const rb = p.locator('button[data-r]').first(); if (!(await rb.count())) break; steps.push(await rb.innerText()); await rb.click(); await p.waitForTimeout(900); hideToast(p); }
  note('Rider steps: ' + steps.join(' → '));
  ok(steps.length >= 2, '8.01', 'rider can walk the pool to delivered', steps.join(' → '));
  const pool = await p.evaluate(async id => (await api.myOrders([id]))[0].pool_status, ama.id);
  ok(pool === 'delivered', '8.02', 'pool shows delivered', pool);

  setArea('9. Drop point (host)');
  await go(p, '#host-demoh1', 1500); v = await view(p);
  note('Host screen: ' + v.slice(0, 500));
  const amaO = await p.evaluate(async id => (await api.myOrders([id]))[0], ama.id);
  const codeIn = p.locator('[data-codeform] input, #code, input[name=code]').first();
  if (await codeIn.count()) { await codeIn.fill(amaO.code); await p.locator('[data-codeform] button, [data-codeform] .btn').first().click(); await p.waitForTimeout(900); }
  v = await view(p); note('Host after code: ' + v.slice(0, 300));
  const amaH = await p.evaluate(async id => (await api.myOrders([id]))[0], ama.id);
  ok(amaH.status === 'collected', '9.01', 'host checks Ama\'s code: collected', amaH.status);
  // wrong code
  if (await codeIn.count()) { await codeIn.fill('Z-99'); await p.locator('[data-codeform] button, [data-codeform] .btn').first().click(); await p.waitForTimeout(700); }
  ok(/not|No|wrong|isn't|check/i.test(await view(p)), '9.02', 'wrong code is refused');

  setArea('10. After delivery');
  await go(p, '#order', 1400); await p.evaluate(() => { refreshMine(); setTab('orders'); }); await p.waitForTimeout(900);
  ot = await txt(p, '#tabOrders'); note('Orders after delivery: ' + ot.slice(0, 500));
  const got = p.locator(`[data-gotit="${ama.id}"]`);
  ok(await got.count() >= 1, '10.01', '"Got my food" offered', await got.count());
  if (await got.count()) { await got.first().click(); await p.waitForTimeout(900); }
  const sh = await txt(p, '#sheet'); ok(/How was lunch/.test(sh), '10.02', 'review opens', sh.slice(0, 120));
  await p.click('#rvSend'); await p.waitForTimeout(300); ok(/Tap the stars/.test(await txt(p, '#rvErr')), '10.02b', 'rating needs stars');
  await p.click('#rvStars [data-s="5"]'); await p.fill('#rvText', 'Hot and on time'); await p.click('#rvSend'); await p.waitForTimeout(1000);
  const rev = await p.evaluate(async () => { await refreshMine(); const m = (S.mine || []).filter(o => !o.parent_id); return m.map(o => o.code + ':' + o.status + ':' + (o.my_rating || '-') + ':' + (o.received_at ? 'rcv' : '')); });
  ok(rev.some(x => /:4:|:5:/.test(x)), '10.03', 'rating saved', rev.join(' | '));
  // Kofi never taps: auto-received 2h after delivered, review asked next open
  await p.evaluate(o => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: o.id, order_date: o.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); }, others.kofi);   // now look from Kofi's side
  await tick(p, '2026-11-09T14:40:00Z'); await p.evaluate(async () => { S.reviewAskedThisVisit = false; await refreshMine(); }); await p.waitForTimeout(1800);   // demo data lives in memory, so "next open" = a fresh refresh
  const kofi3 = await p.evaluate(async id => (await api.myOrders([id]))[0], others.kofi.id);
  ok(kofi3.status === 'collected' && kofi3.received_at, '10.04', 'Kofi auto-received after 2 h', kofi3.status + ' ' + kofi3.received_at);
  const sh2 = await txt(p, '#sheet'); ok(/How was lunch/.test(sh2), '10.05', 'review asked on next open', sh2.slice(0, 120));
  await p.evaluate(() => closeSheet());
  await p.evaluate(async () => { S.reviewAskedThisVisit = false; await refreshMine(); }); await p.waitForTimeout(1600); ok(!(await p.evaluate(() => $('#sheetBg')?.classList.contains('open'))), '10.06', 'review not asked twice');
  // vendor + admin see the day done
  await go(p, '#kitchen-demok1', 1400); if (await p.locator('[data-kday="2026-11-09"]').count()) { await p.click('[data-kday="2026-11-09"]'); await p.waitForTimeout(700); } v = await view(p); ok(/Done|done/.test(v), '10.07', 'vendor sees Done', v.slice(0, 300));
  await go(p, '#admin', 1800); v = await view(p); note('Admin home after the day: ' + v.slice(0, 500));
  const wallet = await p.evaluate(async () => { await refreshUser(); return S.balance; }); note('Wallet balance on this phone (guest, no account): ' + wallet);
  ok(p.errs.length === 0, '10.x', 'no page errors', p.errs.join(' | '));
  require('fs').writeFileSync('/tmp/e2e/res-life.json', JSON.stringify(results, null, 1));
  await b.close();
})();
