/* CCF Makati Sports: service worker (installable app + offline fallback)
 *
 * Rules (kept deliberately simple so an update can never get stuck):
 *  - Pages (HTML): network first. Online = always the latest deploy; the saved
 *    copy is used ONLY when the network fails (offline / no signal).
 *  - The site's own scripts, styles and manifests: also network first, so a new
 *    page never runs with an old script.
 *  - Images, icons, PDFs and the font/icon/library CDNs: served from the saved
 *    copy for speed, refreshed in the background.
 *  - Everything else (Supabase API, storage, realtime, other sites): not
 *    touched at all; it goes straight to the network.
 *  - Bump VERSION to drop all old saved copies on the next visit.
 *
 * Emergency off switch: replace this file's contents with
 *   self.addEventListener('install',()=>self.skipWaiting());
 *   self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.map(c=>caches.delete(c))))
 *     .then(()=>self.registration.unregister()).then(()=>self.clients.matchAll()).then(cs=>cs.forEach(c=>c.navigate(c.url)))));
 * and deploy: every installed copy clears itself and goes back to plain website behaviour.
 */
const VERSION = 'ccf-v1';
const SHELL = [
  '/',
  '/admin.html',
  '/tournament-format.js',
  '/logo.jpg?v=2',
  '/manifest.webmanifest',
  '/admin.webmanifest',
  '/icons/icon-192.png',
  '/icons/apple-touch-icon.png'
];
const CDN_HOSTS = ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(VERSION)
      // cache:'reload' so the shell is fetched fresh, not from the HTTP cache.
      // A missing file must not block the install, so each is added on its own.
      .then(cache => Promise.all(SHELL.map(url =>
        cache.add(new Request(url, { cache: 'reload' })).catch(() => {})
      )))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function saveCopy(request, response, allowOpaque) {
  // Only keep complete, successful responses (CDN <script>/<link> files come
  // back "opaque", which is fine to keep for those hosts only).
  if (!response) return;
  const ok = (response.status === 200 && (response.type === 'basic' || response.type === 'cors'))
          || (allowOpaque && response.type === 'opaque');
  if (!ok) return;
  const copy = response.clone();
  caches.open(VERSION).then(cache => cache.put(request, copy)).catch(() => {});
}

async function networkFirstFile(request) {
  try {
    const response = await fetch(request);
    saveCopy(request, response);
    return response;
  } catch (err) {
    return (await caches.match(request, { ignoreSearch: true })) || Response.error();
  }
}

async function networkFirstPage(request) {
  try {
    const response = await fetch(request);
    saveCopy(request, response);
    return response;
  } catch (err) {
    const url = new URL(request.url);
    const fallbackPath = url.pathname.startsWith('/admin') ? '/admin.html' : '/';
    return (await caches.match(request, { ignoreSearch: true }))
        || (await caches.match(fallbackPath))
        || new Response(
             '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">' +
             '<title>Offline</title><body style="font-family:system-ui,sans-serif;padding:32px;color:#0F1729">' +
             '<h1 style="font-size:20px">You\'re offline</h1><p>Check your connection and try again.</p></body>',
             { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
  }
}

async function savedThenRefresh(request, allowOpaque) {
  const cached = await caches.match(request);
  const refresh = fetch(request).then(response => { saveCopy(request, response, allowOpaque); return response; }).catch(() => null);
  return cached || (await refresh) || Response.error();
}

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.origin === self.location.origin) {
    if (url.pathname === '/sw.js') return;                       // the browser manages this one
    if (request.mode === 'navigate' || request.destination === 'document') {
      event.respondWith(networkFirstPage(request));
      return;
    }
    if (['script', 'style', 'manifest', 'worker'].includes(request.destination)) {
      event.respondWith(networkFirstFile(request));
      return;
    }
    event.respondWith(savedThenRefresh(request, false));
    return;
  }
  if (CDN_HOSTS.includes(url.hostname)) {
    event.respondWith(savedThenRefresh(request, true));
  }
  // Anything else (Supabase etc.) is not intercepted.
});
