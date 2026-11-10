// Shared helpers for the end-to-end runs against the demo build
const { chromium, devices } = require('playwright');
const URL = 'http://localhost:8765/index.html';
const results = [];
let area = '';
const setArea = a => { area = a; console.log('\n## ' + a); };
const ok = (c, id, m, extra) => { results.push({ area, id, ok: !!c, m, extra }); console.log((c ? 'ok  ' : 'FAIL') + ' ' + id + ' ' + m + (extra ? ' | ' + String(extra).slice(0, 220) : '')); };
const note = m => { results.push({ area, id: 'note', ok: null, m }); console.log('NOTE ' + m); };
async function phone(b, opt = {}) {
  const ctx = await b.newContext({ ...devices[opt.device || 'iPhone 14'], colorScheme: opt.scheme || 'light', ...(opt.viewport ? { viewport: opt.viewport } : {}), ...(opt.geo ? { geolocation: opt.geo, permissions: ['geolocation'] } : {}), ...(opt.touch ? { hasTouch: true, isMobile: true } : {}) });
  const p = await ctx.newPage(); p.errs = []; p.on('pageerror', e => p.errs.push(e.message));
  await p.route(/tile\.openstreetmap|cdnjs|nominatim|jsdelivr/, r => r.abort());
  if (opt.time) await p.clock.install({ time: new Date(opt.time) });
  await p.addInitScript(o => {
    localStorage.setItem('cp_splash_v', '1');
    if (!o.fresh) ['cp_intro_done', 'cp_intro_kitchen', 'cp_intro_rider', 'cp_intro_host'].forEach(k => localStorage.setItem(k, 'true'));
    if (o.site) localStorage.setItem('cp_site', JSON.stringify(o.site));
    if (o.me) localStorage.setItem('cp_me', JSON.stringify(o.me));
  }, { fresh: !!opt.fresh, site: opt.site === undefined ? 's1' : opt.site, me: opt.me || null });
  await p.goto(URL + (opt.hash || '')); await p.waitForTimeout(opt.wait || 1500);
  return p;
}
const txt = async (p, sel) => (await p.locator(sel).first().innerText().catch(() => '')).replace(/\s+/g, ' ');
const hideToast = p => p.evaluate(() => document.querySelectorAll('.toast').forEach(t => t.classList.remove('show')));
module.exports = { chromium, URL, results, setArea, ok, note, phone, txt, hideToast };
