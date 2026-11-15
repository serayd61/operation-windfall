// Offline support. Bump VERSION on every release so installed copies pick up the new files.
const VERSION = 'windfall-28';
const SHELL = ['./', 'index.html', 'privacy.html', 'vendor/three.min.js', 'vendor/supabase.js', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/favicon.svg'];
self.addEventListener('install', e => { e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url), fonts = url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
  if (url.origin !== location.origin && !fonts) return;
  const put = res => { if (res && (res.ok || res.type === 'opaque')) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); } return res; };
  if (req.mode === 'navigate') { // the page itself: fresh when online, cached when not
    e.respondWith(fetch(req).then(put).catch(() => caches.match(req).then(r => r || caches.match('index.html')))); return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(put)));
});
