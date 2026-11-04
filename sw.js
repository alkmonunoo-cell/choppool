// ChopPool service worker: opens fast and offline (app shell), always fetches fresh data, shows push alerts.
const CACHE = "choppool-v14";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icons/icon-192-v2.png", "./icons/icon-512-v2.png", "./icons/apple-touch-icon-v2.png",
  "./fonts/plus-jakarta-sans.woff", "./fonts/bricolage-grotesque.woff"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
// Files that never change once published (fonts, map library, the versioned Supabase library): cache first
const immutable = u => (u.origin === location.origin && /\/(fonts|vendor)\//.test(u.pathname)) || (u.hostname === "cdn.jsdelivr.net" && /@\d+\.\d+\.\d+/.test(u.pathname));
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  if (immutable(u)) {
    e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request).then(r => { if (r.ok || r.type === "opaque") { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); } return r; })));
    return;
  }
  if (u.origin !== location.origin) return;          // data (Supabase, maps, dish photos) always goes to the network
  // Always ask the server for the newest page (skips the browser's 10-minute cache), fall back to the saved copy offline
  const fresh = e.request.mode === "navigate" ? fetch(e.request.url, { cache: "no-cache", credentials: "same-origin" }) : fetch(e.request, { cache: "no-cache" });
  e.respondWith(fresh.then(r => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); } return r; })
    .catch(() => caches.match(e.request).then(r => r || caches.match("./index.html"))));
});
self.addEventListener("push", e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: "ChopPool", body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "ChopPool", { body: d.body || "", icon: "icons/icon-192-v2.png", badge: "icons/icon-192-v2.png", tag: d.tag, data: { url: d.url || "./" } }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(ws => { for (const w of ws) { if ("focus" in w) { w.navigate(url).catch(() => {}); return w.focus(); } } return self.clients.openWindow(url); }));
});
