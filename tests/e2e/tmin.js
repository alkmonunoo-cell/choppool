const { chromium, phone, ok, txt } = require('./h');
(async () => { const b = await chromium.launch();
  const p = await phone(b, { time: '2026-11-09T09:00:00Z', viewport: { width: 390, height: 900 } });
  await p.evaluate(() => location.hash = '#admin'); await p.waitForTimeout(1800);
  await p.evaluate(() => document.querySelector('[data-atab="riders"]').click()); await p.waitForTimeout(400);
  await p.evaluate(() => document.querySelector('[data-asub="rules"]').click()); await p.waitForTimeout(700);
  ok(await p.locator('[name=trip_min]').count() === 1, 'm.1', 'Lowest trip price box');
  await p.fill('[name=base_fare]', '5'); await p.fill('[name=per_km]', '5'); await p.fill('[name=trip_min]', '10'); await p.fill('[name=trip_max]', '100');
  const ex = await txt(p, '#pfEx');
  ok(/1 km trip GHS 10\.00 · 2 km GHS 15\.00 · 5 km GHS 30\.00 · 10 km GHS 55\.00/.test(ex), 'm.2', 'examples follow what you type, with the minimum', ex);
  await p.fill('[name=trip_min]', '200'); await p.click('form[data-form="settings"] .savebar .btn'); await p.waitForTimeout(400);
  ok(/can't be above the highest/.test(await txt(p, 'form[data-form="settings"] [data-err]')), 'm.3', 'lowest above highest is refused');
  await p.fill('[name=trip_min]', '10'); await p.click('form[data-form="settings"] .savebar .btn'); await p.waitForTimeout(800);
  ok(await p.evaluate(() => Number(S.settings.trip_min) === 10 && Number(S.settings.base_fare) === 5), 'm.4', 'saved');
  // a vendor right next to a building now prices at the minimum
  const t = await p.evaluate(() => { const st = S.sites[0]; return tripFor({ lat: st.lat + 0.0003, lng: st.lng }, st, S.settings); });
  ok(t === 10, 'm.5', 'very short trip charges the lowest price', t);
  console.log(p.errs); await b.close(); })();
