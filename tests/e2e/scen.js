// Edge cases and "what if" flows, each on a fresh demo phone
const { chromium, results, setArea, ok, note, phone, txt, hideToast } = require('./h');
const go = async (p, h, w = 1300) => { await p.evaluate(h => { location.hash = h; }, h); await p.waitForTimeout(w); };
const view = p => txt(p, '#view');
const mine = (p, o) => p.evaluate(o => { const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: o.id, order_date: o.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); }, o);
const get = (p, id) => p.evaluate(async id => (await api.myOrders([id]))[0], id);
const unconfirm = (p, tok, d) => p.evaluate(async ([t, d]) => { d = d || opsDate(); await api.kitchenPause(t, d, true); await api.kitchenPause(t, d, false); await refreshBoard().catch(() => {}); }, [tok, d]);
(async () => {
  const b = await chromium.launch();

  setArea('11. Vendor can\'t cook');
  let p = await phone(b, { time: '2026-11-09T07:30:00Z' });
  await unconfirm(p, 'demok1');
  let o1 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0241112223', ref: '51234567890' }));
  await p.evaluate(id => api.updateOrder(id, { status: 'paid' }), o1.id); await mine(p, o1);
  await go(p, '#kitchen-demok1');
  ok(await p.locator('#skipDay').count() === 1, '11.01', 'vendor has "Not cooking today?" while customers wait');
  await p.click('#skipDay'); await p.waitForTimeout(400);
  ok(/money back/i.test(await txt(p, '#sheet')), '11.02', 'vendor is told customers get their money back', await txt(p, '#sheet'));
  await p.click('#skipYes'); await p.waitForTimeout(900);
  let x = await get(p, o1.id); ok(x.status === 'cancelled' && /isn't cooking/.test(x.cancel_reason), '11.03', 'waiting order cancelled', x.status + ' ' + x.cancel_reason + ' refund_needed ' + x.refund_needed);
  await go(p, '#order'); await p.evaluate(() => setTab('orders')); await p.waitForTimeout(700);
  ok(/isn't cooking today/.test(await txt(p, '#tabOrders')), '11.04', 'customer told why + money back', (await txt(p, '#tabOrders')).slice(0, 260));
  await p.evaluate(async () => { await refreshBoard(); openVendor('k1'); }); await p.waitForTimeout(800); const vb5 = await txt(p, '#vpage');
  ok(/paused|not cooking|isn't cooking|Not taking orders|closed|tomorrow/i.test(vb5), '11.05', 'menu shows the vendor is off today', vb5.slice(0, 300));
  await p.evaluate(() => closeVendor(true));
  // vendor times out instead
  await unconfirm(p, 'demok2');
  const o2 = await p.evaluate(() => api.placeOrder({ site: 's1', item: Object.values(S.items).find(i => i.kitchen_id === 'k2').id, qty: 1, name: 'Kofi', phone: '0201234567', ref: '52223334445' }));
  await mine(p, o2); await p.clock.setSystemTime(new Date('2026-11-09T08:31:00Z')); await p.evaluate(() => refreshMine()); await p.waitForTimeout(700);
  x = await get(p, o2.id); ok(x.status === 'cancelled' && /did not confirm/.test(x.cancel_reason), '11.06', 'no confirm by 8:30: cancelled', x.status + ' ' + x.cancel_reason);
  // vendor already confirmed: skip refused
  await p.evaluate(async () => { await api.kitchenOpenDay('demok2', opsDate()); });
  const o3 = await p.evaluate(() => api.placeOrder({ site: 's1', item: Object.values(S.items).find(i => i.kitchen_id === 'k2').id, qty: 1, name: 'Esi', phone: '0551234567', ref: '53334445556' }));
  const sk = await p.evaluate(async () => { try { await api.kitchenSkipDay('demok2', opsDate()); return 'allowed'; } catch (e) { return e.message; } });
  ok(/already confirmed/.test(sk), '11.07', 'after confirming, vendor must message ChopPool instead', sk);
  ok(p.errs.length === 0, '11.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('12. Cancelling');
  p = await phone(b, { time: '2026-11-09T07:30:00Z' });
  const c1 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '51234567890' })); await mine(p, c1);
  await p.evaluate(() => { refreshMine(); setTab('orders'); }); await p.waitForTimeout(700);
  ok(await p.locator(`[data-cancel="${c1.id}"]`).count() === 1, '12.01', 'cancel offered before cut-off');
  await p.click(`[data-cancel="${c1.id}"]`); await p.waitForTimeout(400);
  note('Cancel sheet (pending payment): ' + (await txt(p, '#sheet')).slice(0, 300));
  await p.check('[name=why][value=Other]'); await p.locator('#cancelForm .btn').click(); await p.waitForTimeout(300);
  ok(/Tell us briefly/.test(await txt(p, '#cancelErr')), '12.02', '"Other" needs a reason');
  await p.fill('#whyOther', 'Meeting moved to lunch time'); await p.locator('#cancelForm .btn').click(); await p.waitForTimeout(900);
  x = await get(p, c1.id); ok(x.status === 'cancelled' && /Other: Meeting/.test(x.cancel_reason), '12.03', 'cancelled with reason', x.cancel_reason);
  // After the vendor confirmed the final batch: no cancel
  const c2 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '51234567891' })); await mine(p, c2);
  await p.evaluate(async id => { await api.updateOrder(id, { status: 'paid' }); const o = (await api.myOrders([id]))[0]; await api.updatePool(o.pool_id, { status: 'accepted' }); }, c2.id);
  await p.evaluate(() => refreshMine()); await p.waitForTimeout(700);
  ok(await p.locator(`[data-cancel="${c2.id}"]`).count() === 0, '12.04', 'no cancel once vendor is cooking');
  const cx = await p.evaluate(async id => { try { await api.cancelOrder(id, 'x'); return 'allowed'; } catch (e) { return e.message; } }, c2.id);
  note('Server-side cancel after vendor confirmed batch (before cut-off): ' + cx);
  // After cut-off
  await p.clock.setSystemTime(new Date('2026-11-09T10:35:00Z'));
  const c3 = await p.evaluate(async () => { try { const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '51234567892' }); return r.order_date; } catch (e) { return 'ERR ' + e.message; } });
  ok(c3 === '2026-11-10', '12.05', 'order after cut-off goes to tomorrow', c3);
  ok(p.errs.length === 0, '12.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('13. Evening before');
  p = await phone(b, { time: '2026-11-08T19:00:00Z' });
  await unconfirm(p, 'demok1', '2026-11-09');
  await p.evaluate(() => openVendor('k1')); await p.waitForTimeout(800);
  const vb = await txt(p, '#vpBanner'); note('Sunday 19:00 banner: ' + vb);
  const e1 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '51234567890' }));
  ok(e1.order_date === '2026-11-09', '13.01', 'evening order is for Monday', e1.order_date);
  await mine(p, e1); await p.evaluate(() => { closeVendor(true); refreshMine(); setTab('orders'); }); await p.waitForTimeout(800);
  const et = await txt(p, '#tabOrders'); note('Evening order card: ' + et.slice(0, 300));
  ok(/8:30|08:30/.test(et) || /tomorrow|Mon/i.test(et), '13.02', 'card says when the vendor must confirm', et.slice(0, 200));
  const wu = await p.evaluate(async id => (await api.myOrders([id]))[0].wait_until, e1.id); ok(/T08:30/.test(wu || ''), '13.03', 'confirm deadline 08:30 next morning', wu);
  ok(p.errs.length === 0, '13.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('14. Special requests');
  p = await phone(b, { time: '2026-11-09T08:00:00Z' });
  const s1 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '', special: 'Jollof with goat, no pepper' })); await mine(p, s1);
  x = await get(p, s1.id); ok(x.status === 'quote_requested', '14.01', 'special waits for a price', x.status);
  await go(p, '#kitchen-demok1'); ok(await p.locator('#specials').count() === 1, '14.02', 'vendor sees the special request');
  await p.locator(`[data-decline="${s1.id}"]`).click(); await p.waitForTimeout(400); await p.fill('#decWhy', 'No goat today'); await p.click('#decYes'); await p.waitForTimeout(900);
  x = await get(p, s1.id); ok(x.status === 'cancelled' && /can't/.test(x.cancel_reason), '14.03', 'vendor declines, customer told', x.cancel_reason);
  // priced but not paid in time
  const s2 = await p.evaluate(() => api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '', special: 'Extra spicy jollof' })); await mine(p, s2);
  await go(p, '#kitchen-demok1'); await p.locator(`[data-quote="${s2.id}"] input`).first().fill('65'); await p.locator(`[data-quote="${s2.id}"] .btn`).click(); await p.waitForTimeout(800);
  x = await get(p, s2.id); ok(x.status === 'quoted', '14.04', 'vendor prices it', x.status + ' ' + x.quote_price);
  await p.clock.setSystemTime(new Date('2026-11-09T08:20:00Z')); await go(p, '#order'); await p.evaluate(() => refreshMine()); await p.waitForTimeout(800);
  x = await get(p, s2.id); ok(x.status === 'cancelled', '14.05', 'priced request not paid in 15 min: cancelled', x.status + ' ' + x.cancel_reason);
  // special after 10:00
  await p.clock.setSystemTime(new Date('2026-11-09T10:05:00Z'));
  const s3 = await p.evaluate(async () => { try { await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama', phone: '0241112223', ref: '', special: 'x y z' }); return 'allowed'; } catch (e) { return e.message; } });
  ok(/close at/.test(s3), '14.06', 'special requests close at 10:00', s3);
  ok(p.errs.length === 0, '14.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('15. Limits');
  p = await phone(b, { time: '2026-11-09T08:00:00Z' });
  const full = await p.evaluate(async () => { const out = []; for (let i = 0; i < 6; i++) { try { const r = await api.placeOrder({ site: 's2', item: 'i1', qty: 5, name: 'P' + i, phone: '02400000' + (10 + i), ref: '5000000000' + i }); out.push(r.pool_seq + ':' + r.meals); } catch (e) { out.push('ERR ' + e.message); } } return out; });
  note('15 meals max per pool, 5 a time: ' + full.join(' | '));
  ok(full.some(r => /^2:/.test(r)), '15.01', 'a full pool starts pool 2', full.join(' | '));
  const cap = await p.evaluate(async () => { const out = []; for (let i = 0; i < 14; i++) { try { await api.placeOrder({ site: 's3', item: 'i1', qty: 5, name: 'C' + i, phone: '02000000' + (10 + i), ref: '6000000000' + i }); out.push('ok'); } catch (e) { out.push(e.message); } } return out; });
  ok(cap.some(r => /fully booked/.test(r)), '15.02', 'vendor capacity stops orders', cap.filter(r => r !== 'ok').slice(0, 2).join(' | '));
  const tray9 = await p.evaluate(async () => { try { await api.placeBasket({ site: 's1', lines: [{ item: 'i1', qty: 6 }, { item: 'i2', qty: 5 }], name: 'T', phone: '0277777777', ref: '5888888888' }); return 'allowed'; } catch (e) { return e.message; } });
  ok(/Up to 10 meals/.test(tray9), '15.03', 'tray max 10 meals', tray9);
  const mix = await p.evaluate(async () => { const k2 = S.items.find(i => i.kitchen_id === 'k2'); try { await api.placeBasket({ site: 's1', lines: [{ item: 'i1', qty: 1 }, { item: k2.id, qty: 1 }], name: 'T', phone: '0277777777', ref: '5888888888' }); return 'allowed'; } catch (e) { return e.message; } });
  ok(/one vendor/.test(mix), '15.04', 'tray from one vendor only', mix);
  const noRef = await p.evaluate(async () => { try { await api.placeBasket({ site: 's1', lines: [{ item: 'i1', qty: 1 }], name: 'T', phone: '0277777778', ref: '' }); return 'allowed'; } catch (e) { return e.message; } });
  ok(/transaction ID|fully booked/.test(noRef), '15.05', 'transaction ID required', noRef);
  ok(p.errs.length === 0, '15.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('16. Links and wrong input');
  p = await phone(b, { time: '2026-11-09T08:00:00Z' });
  for (const h of ['#kitchen-nope', '#rider-nope', '#host-nope']) { await go(p, h); ok(/not valid|isn't valid|no longer|Ask/i.test(await view(p)), '16.' + h.slice(1, 4), h + ' shows a clear message', (await view(p)).slice(0, 140)); }
  await go(p, '#order'); await p.evaluate(() => openVendor('k1')); await p.waitForTimeout(700);
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300); await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(700);
  await p.fill('#fName', ''); await p.fill('#fPhone', '12345'); await p.fill('#fRef', '1'); await p.click('#submitBtn'); await p.waitForTimeout(600);
  note('Checkout with bad input: ' + (await p.$$eval('#sheet .err', e => e.map(x => x.innerText).filter(Boolean).join(' / '))));
  ok((await p.$$eval('#sheet .err', e => e.map(x => x.innerText).filter(Boolean))).length > 0, '16.04', 'bad name/phone/ID are refused with a message');
  ok(p.errs.length === 0, '16.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  setArea('17. Account and wallet');
  p = await phone(b, { time: '2026-11-09T08:00:00Z' });
  await p.evaluate(() => setTab('wallet')); await p.waitForTimeout(600);
  note('Account tab signed out: ' + (await txt(p, '#tabWallet')).slice(0, 200));
  const acc = await p.evaluate(async () => { try { await api.signUp('ama@test.com', 'secret12', 'Ama Owusu'); await refreshUser(); return S.user && S.user.email; } catch (e) { return 'ERR ' + e.message; } });
  ok(acc === 'ama@test.com', '17.01', 'sign up', acc);
  const dup = await p.evaluate(async () => { try { await api.signUp('ama@test.com', 'secret12', 'Ama'); return 'allowed'; } catch (e) { return e.message; } });
  ok(/already has an account/.test(dup), '17.02', 'same email twice refused', dup);
  // account order, cancel paid -> wallet
  const w1 = await p.evaluate(async () => { const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0241112223', ref: '51234567890' }); await api.updateOrder(r.id, { status: 'paid' }); const m = JSON.parse(localStorage.getItem('cp_orders') || '[]'); m.push({ id: r.id, order_date: r.order_date }); localStorage.setItem('cp_orders', JSON.stringify(m)); return r; });
  await p.evaluate(() => { refreshMine(); setTab('orders'); }); await p.waitForTimeout(800);
  await p.click(`[data-cancel="${w1.id}"]`); await p.waitForTimeout(400);
  ok(await p.locator('#cancelForm [name=to][value=wallet]').count() === 1, '17.03', 'paid order: refund to wallet or mobile money');
  await p.locator('#cancelForm .btn').click(); await p.waitForTimeout(900);
  const bal = await p.evaluate(async () => { await refreshUser(); return S.balance; }); ok(bal > 0, '17.04', 'money back in wallet', bal);
  // pay with wallet
  const w2 = await p.evaluate(async () => { try { const r = await api.placeOrder({ site: 's1', item: 'i1', qty: 1, name: 'Ama Owusu', phone: '0241112223', ref: '', useWallet: true }); return r.status; } catch (e) { return 'ERR ' + e.message; } });
  ok(w2 === 'paid', '17.05', 'whole order paid from wallet, no ID needed', w2);
  await p.evaluate(() => setTab('wallet')); await p.waitForTimeout(700); note('Account tab signed in: ' + (await txt(p, '#tabWallet')).slice(0, 300));
  const so = await p.evaluate(async () => { await api.signOut(); await refreshUser(); return !!S.user; }); ok(!so, '17.06', 'sign out');
  const bad = await p.evaluate(async () => { try { await api.signIn('ama@test.com', 'wrongpw'); return 'allowed'; } catch (e) { return e.message; } }); ok(/Wrong/.test(bad), '17.07', 'wrong password refused', bad);
  ok(p.errs.length === 0, '17.x', 'no page errors', p.errs.join(' | ')); await p.context().close();

  require('fs').writeFileSync('/tmp/e2e/res-scen.json', JSON.stringify(results, null, 1));
  await b.close();
})();
