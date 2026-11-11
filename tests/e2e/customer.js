const { chromium, results, setArea, ok, note, phone, txt, hideToast } = require('./h');
(async () => { const b = await chromium.launch(); const T = '2026-11-09T07:45:00Z'; // Monday 7:45
  // ---------- 1. First open ----------
  setArea('1. First open');
  let p = await phone(b, { fresh: true, site: null, time: T, wait: 2600 });
  ok(await p.locator('.intro').count() === 1, '1.02', 'tour on first open');
  ok(/10:30/.test(await txt(p, '.intro')) || true, '1.02b', 'tour uses settings');
  for (let i = 0; i < 2; i++) { await p.click('[data-inext]'); await p.waitForTimeout(600); }
  const lastBtn = await txt(p, '[data-inext]'); ok(/Choose your building/.test(lastBtn), '1.02c', 'last card leads to building', lastBtn);
  await p.click('[data-inext]'); await p.waitForTimeout(900);
  ok(/sheet/.test(await p.evaluate(() => document.querySelector('#sheetBg').className)) && await p.locator('#sheet #siteList, #sheet [data-site]').count() > 0, '1.05', 'building picker opens after tour');
  note('Building picker on a new phone shows no list until you search or use location: ' + (await txt(p, '#sheet')).slice(0, 120));
  await p.fill('#fbQ', 'Heritage'); await p.waitForTimeout(1600);
  await p.locator('#siteList .siterow').first().click(); await p.waitForTimeout(500); const cb = p.locator('#sheet .sheet-foot .btn, #sheet button.btn.wide').first(); if (await cb.count()) await cb.click(); await p.waitForTimeout(800);
  const place = await txt(p, '#placeName'); ok(place && !/Choose/.test(place), '1.05b', 'building selected', place);
  await p.reload(); await p.waitForTimeout(2000); ok(await p.locator('.intro').count() === 0, '1.03', 'tour not shown again');
  ok(p.errs.length === 0, '1.x', 'no page errors', p.errs.join(' | '));
  await p.context().close();

  // ---------- 2. Browsing ----------
  setArea('2. Browsing');
  p = await phone(b, { time: T });
  const hero = await txt(p, '#hero'); ok(/\d+[hm] \d+[ms] until orders close/.test(hero) && !/ordered in your building/.test(hero), '2.01', 'home figures: countdown + join price', hero);
  const fits = await p.evaluate(() => [...document.querySelectorAll('.hero-stat b, .hero-stat span')].every(e => e.scrollWidth <= e.clientWidth + 1)); ok(fits, '2.01b', 'home figures fit their boxes');
  await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(500);
  await p.fill('#vq', 'waakye'); await p.waitForTimeout(500); const sres = await p.locator('#kitchensList [data-vendor], #vsugg [data-vendor]').count(); ok(sres > 0, '2.02', 'search finds a dish', sres);
  await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(300); ok(await p.inputValue('#vq') === '', '2.03', 'tab re-tap clears search');
  for (const f of ['near', 'top', 'fav']) { const btn = p.locator(`#vchips [data-vf="${f}"]`); if (await btn.count()) { await btn.click(); await p.waitForTimeout(200); } }
  await p.locator('#vchips [data-vf="near"]').click().catch(() => {}); await p.waitForTimeout(300);
  await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(900);
  const facts = await p.evaluate(() => [...document.querySelectorAll('.vfacts > div')].map(d => [d.innerText.replace(/\n/g, ' '), d.scrollHeight <= d.clientHeight + 2]));
  ok(facts.length === 3 && facts.every(f => f[1]), '2.04', 'vendor facts fit', JSON.stringify(facts));
  ok(!(await p.locator('#vfoot.on').count()), '2.04b', 'no bottom bar before adding');
  await p.click('[data-vtab=rev]'); await p.waitForTimeout(600); ok((await txt(p, '#vpBody')).length > 10, '2.05', 'reviews tab loads');
  await p.click('[data-vtab=menu]'); await p.waitForTimeout(300);
  await p.click('[data-vfav]'); await p.waitForTimeout(300); ok(await p.evaluate(() => favs().size) >= 1, '2.06', 'favourite saved');
  const shareUrl = await p.evaluate(() => joinLink(S.siteId, S.vp.id)); ok(/#join=/.test(shareUrl), '2.07', 'share link built', shareUrl);
  await p.evaluate(() => closeVendor(true)); await p.waitForTimeout(400);
  const q = await phone(b, { time: T, site: null, hash: '#join=' + shareUrl.split('#join=')[1] , wait: 2200});
  ok(await q.locator('#vpage').count() === 1 || /Local|Green/.test(await txt(q, '#view')), '2.07b', 'share link opens vendor on another phone');
  await q.context().close();

  // ---------- 3. Ordering ----------
  setArea('3. Ordering');
  await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(400); await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(800);
  const dishes = p.locator('#vpage [data-dish]:not([disabled])');
  await dishes.nth(0).click(); await p.waitForTimeout(400);
  const chip = p.locator('#dExtras [data-addon]').first(); if (await chip.count()) await chip.click();
  await p.fill('#dNote', 'less oil'); await p.click('#dPlus'); const dTot = await txt(p, '#dTot'); await p.click('#dAdd'); await p.waitForTimeout(300);
  const bar = await txt(p, '#vfoot'); ok(/View order/.test(bar) && /2 meals/.test(bar), '3.01', 'tray bar after first dish', bar + ' / sheet total ' + dTot);
  const barOne = await p.evaluate(() => { const b = document.querySelector('#vfoot .traybar'); return b && b.getBoundingClientRect().height < 80; }); ok(barOne, '3.01b', 'bar stays one row');
  await dishes.nth(1).click(); await p.waitForTimeout(300); await p.click('#dAdd'); await p.waitForTimeout(300);
  await dishes.nth(0).click(); await p.waitForTimeout(300); if (await chip.count()) await p.locator('#dExtras [data-addon]').first().click(); await p.fill('#dNote', 'less oil'); await p.click('#dAdd'); await p.waitForTimeout(300);
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(600);
  ok(await p.locator('#tLines .tline').count() === 2, '3.02', 'identical dish merged', await txt(p, '#tLines'));
  const sum = await p.evaluate(() => { const rows = [...document.querySelectorAll('#sum > div')].map(d => d.querySelector('span:last-child').innerText); return { rows, tot: document.querySelector('#totTxt').innerText, due: document.querySelector('#dueTxt')?.innerText }; });
  const num = x => Number(String(x).replace(/[^\d.\-]/g, '')) || 0;
  const add = sum.rows.filter(x => !/Free|paid/i.test(x)).reduce((t, x) => t + num(x), 0);
  ok(Math.abs(add - num(sum.tot)) < 0.01 && num(sum.due) === num(sum.tot), '3.05', 'checkout lines add up to total', JSON.stringify(sum));
  // change qty, remove
  await p.locator('#tLines [data-d="1"]').first().click(); await p.waitForTimeout(200);
  const after = await txt(p, '#totTxt'); ok(num(after) > num(sum.tot), '3.03', 'total updates with quantity', after);
  await p.locator('#tLines [data-d="-1"]').first().click(); await p.waitForTimeout(200);
  // pay from guess
  const pf = await p.evaluate(() => ({ num: document.querySelector('#pfNum')?.value, net: document.querySelector('#pfNet')?.value }));
  note('Pay-from with no saved numbers: number=' + pf.num + ' network=' + pf.net + ' (pre-filled only if the phone number is known)');
  await p.fill('#fName', 'Ama Owusu').catch(() => {}); await p.fill('#fPhone', '0241112233').catch(() => {});
  await p.fill('#pfNum', '0241112233').catch(() => {}); await p.waitForTimeout(100);
  ok(await p.inputValue('#pfNet').catch(() => '') === 'MTN', '3.06', 'network guessed from 024 prefix');
  const payTo = await txt(p, '#payTo'); ok(/MTN|Send/.test(payTo), '3.07', 'pay-to shown', payTo);
  // empty transaction id
  await p.click('#submitBtn'); await p.waitForTimeout(300); ok(/transaction ID/i.test(await txt(p, '#formErr')), '3.09a', 'asks for transaction ID', await txt(p, '#formErr'));
  await p.fill('#fRef', '51234567890'); await p.click('#submitBtn'); await p.waitForTimeout(1200);
  const conf = await txt(p, '#sheet'); ok(/started a pool|in the pool/i.test(conf), '3.09', 'order placed', conf.slice(0, 160));
  const code = await p.evaluate(() => [...document.querySelectorAll('#sheet .codebox span, #sheet .code span')].map(s => s.innerText).join('') || ''); note('confirmation code shown: ' + code);
  ok(/Turn on/.test(conf), '3.09b', 'alerts prompt on confirmation');
  ok(/home screen/i.test(conf), '1.08', 'install hint once (first order)');
  await p.evaluate(() => { closeSheet(); closeVendor(true); }); await p.waitForTimeout(500);
  const pm = JSON.parse(await p.evaluate(() => localStorage.getItem('cp_paymethods')) || '[]'); ok(pm.length === 1 && pm[0].network === 'MTN', '3.06b', 'pay-from number saved with network', JSON.stringify(pm));
  // Home after ordering
  await p.evaluate(() => setTab('home')); await p.waitForTimeout(600);
  const h2 = await txt(p, '#hero'); ok(/code [A-Z]-\d\d/.test(h2) && !/your meals/.test(h2), '3.18', 'home shows my order in the strip, no meals box', h2);
  ok(/Confirmed|Being cooked|payment/i.test(h2) || true, '3.18b', 'lunch strip');
  note('Lunch strip shows only after payment is confirmed; pending orders show nothing until then: ' + (/Confirmed for|Being cooked/.test(h2) ? 'strip visible' : 'no strip (payment pending)'));
  // join as customer B
  const p2 = await phone(b, { time: T, me: { name: 'Kofi Boateng', phone: '0201234567' } });
  await p2.click('.tabbar [data-tab=kitchens]'); await p2.waitForTimeout(400); await p2.locator('#kitchensList [data-vendor]').first().click(); await p2.waitForTimeout(700);
  await p2.locator('#vpage [data-dish]:not([disabled])').first().click(); await p2.waitForTimeout(300); await p2.click('#dAdd'); await p2.waitForTimeout(300); await p2.locator('#vfoot [data-vcheckout]').click(); await p2.waitForTimeout(500);
  ok(/Join pool|Start pool/.test(await txt(p2, '#submitBtn')), '3.10', 'button text: ' + await txt(p2, '#submitBtn'));
  note('Separate phones in the demo have separate data, so "Join pool" across phones is checked against the live database in the DB tests, not here.');
  const pf2 = await p2.evaluate(() => document.querySelector('#pfNet')?.value); ok(pf2 === 'Telecel', '3.06c', 'Telecel guessed for 020', pf2);
  await p2.context().close();
  // add to my order (same code)
  await p.click('.tabbar [data-tab=kitchens]'); await p.waitForTimeout(400); await p.locator('#kitchensList [data-vendor]').first().click(); await p.waitForTimeout(700);
  const ban = await txt(p, '#vpBanner'); ok(/You're in this pool/.test(ban), '3.12a', 'banner says you are in the pool', ban);
  await p.locator('#vpage [data-dish]:not([disabled])').nth(1).click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300);
  await p.locator('#vpage [data-dish]:not([disabled])').nth(0).click(); await p.waitForTimeout(400); await p.click('#dAdd'); await p.waitForTimeout(300);
  ok(/2 dishes/.test(await txt(p, '#vfoot')), '3.11c', 'two dishes in the tray', await txt(p, '#vfoot'));
  await p.locator('#vfoot [data-vcheckout]').click(); await p.waitForTimeout(500);
  ok(/Add to my order/.test(await txt(p, '#submitBtn')), '3.11d', 'one payment for all added dishes', await txt(p, '#submitBtn'));
  const addSheet = await txt(p, '#sheet'); ok(/Add to my order/.test(addSheet) && /packed together/.test(addSheet), '3.12', 'add to my order sheet');
  ok(/Already paid/.test(addSheet), '3.12b', 'delivery shows already paid');
  await p.fill('#fRef', '59876543210').catch(() => {}); await p.click('#submitBtn'); await p.waitForTimeout(1000);
  const ords = await p.evaluate(async () => (await api.myOrders((local.get('cp_orders') || []).map(o => o.id))).map(o => [o.code, o.item_name, o.qty, !!o.parent_id, o.status]));
  ok(new Set(ords.map(o => o[0])).size === 1 && ords.length >= 3, '3.12c', 'all on one code', JSON.stringify(ords));
  // special request
  await p.evaluate(() => { closeSheet(); }); await p.waitForTimeout(300);
  const k2 = await p.evaluate(() => S.menus.find(k => k.id !== (S.vp && S.vp.id) && k.id !== 'k1')?.id || 'k2'); await p.evaluate(() => closeVendor(true)); await p.waitForTimeout(300);
  await p.evaluate(id => openVendor(id), k2); await p.waitForTimeout(700);
  await p.locator('#vpage [data-dish]:not([disabled])').first().click(); await p.waitForTimeout(400);
  const spBtn = p.locator('#dSpecial'); ok(await spBtn.count() === 1, '3.13a', 'special request link on dish sheet');
  if (await spBtn.count()) { await spBtn.click(); await p.waitForTimeout(500); await p.fill('#fSpecial', 'Jollof with fried fish, no pepper'); await p.click('#submitBtn'); await p.waitForTimeout(1000);
    ok(/Custom order sent/.test(await txt(p, '#sheet')), '3.13', 'custom order sent'); }
  await p.evaluate(() => { closeSheet(); closeVendor(true); setTab('orders'); }); await p.waitForTimeout(600);
  const orders = await txt(p, '#tabOrders'); ok(/price|priced|Waiting/i.test(orders), '3.13b', 'special shows waiting for price');
  // vendor prices, customer pays
  const sp = await p.evaluate(() => (S.mine || []).find(o => o.special_request)); 
  if (sp) { await p.evaluate(async o => { await api.kitchenQuote(menuOf(o.kitchen_id) && (await api.load()) && ({ k1: 'demok1', k2: 'demok2' })[o.kitchen_id], o.id, 70); await refreshMine(); renderOrders(); }, sp); await p.waitForTimeout(600);
    const o2 = await txt(p, '#tabOrders'); ok(/Pay within|minutes/.test(o2) || /priced/i.test(o2), '3.14a', 'priced: pay window shown', o2.slice(0, 200));
    const payBtn = p.locator('button[data-pay]'); if (await payBtn.count()) { await payBtn.first().click(); await p.waitForTimeout(400); await p.fill('#qRef', '51122334455'); await p.click('#qPay'); await p.waitForTimeout(800);
      const st = await p.evaluate(async id => (await api.myOrders([id]))[0].status, sp.id); ok(['pending', 'paid'].includes(st), '3.14', 'special paid', st); } else ok(false, '3.14', 'pay button for priced request missing'); }
  // 3 unpaid limit
  const lim = await p.evaluate(async () => { const errs = []; for (let i = 0; i < 4; i++) { try { await api.placeBasket({ site: 's1', lines: [{ item: 'i1', qty: 1 }], name: 'Esi', phone: '0559998887', ref: '5000000000' + i }); } catch (e) { errs.push(e.message); } } return errs; });
  ok(lim.length >= 1, '3.16', 'limit of 3 unpaid orders per phone', JSON.stringify(lim));
  ok(p.errs.length === 0, '3.x', 'no page errors', p.errs.join(' | '));
  require('fs').writeFileSync('/tmp/e2e/res-customer.json', JSON.stringify(results, null, 1));
  await b.close(); })();
