/* CCF Makati Sports: service worker (installable app + offline fallback)
 *
 * Rules (kept deliberately simple so an update can never get stuck):
 *  - Pages (HTML): network first. Online = always the latest deploy; the saved
 *    copy is used ONLY when the network fails (offline / no signal).
 *  - The site's own scripts, styles and manifests: also network first, so a new
 *    page never runs with an old script.
 *  - The site's own images, icons and PDFs: served from the saved copy for
 *    speed, refreshed in the background.
 *  - Everything on other hosts (font/icon/library CDNs, Supabase API,
 *    storage, realtime): NOT touched at all; the browser loads it exactly as
 *    it would without this worker. (A worker's own fetch() is bound by the
 *    site's connect-src CSP, which doesn't list the CDNs, so intercepting
 *    them broke icons and fonts in v1.)
 *  - Bump VERSION to drop all old saved copies on the next visit.
 *
 * Emergency off switch: replace this file's contents with
 *   self.addEventListener('install',()=>self.skipWaiting());
 *   self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.map(c=>caches.delete(c))))
 *     .then(()=>self.registration.unregister()).then(()=>self.clients.matchAll()).then(cs=>cs.forEach(c=>c.navigate(c.url)))));
 * and deploy: every installed copy clears itself and goes back to plain website behaviour.
 */
const VERSION = 'ccf-v2';
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
  event.waitUntil((async () => {
    const keys = await caches.keys();
    // Devices that ran v1 loaded their open page with icons/fonts blocked.
    // Reload those pages once so they come back with icons (only for v1).
    const hadBrokenV1 = keys.includes('ccf-v1');
    await Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)));
    await self.clients.claim();
    if (hadBrokenV1) {
      const windows = await self.clients.matchAll({ type: 'window' });
      windows.forEach(client => { try { client.navigate(client.url); } catch (e) {} });
    }
  })());
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
    // 'no-cache' = always confirm with the server (Cloudflare tells browsers
    // to keep .js for 4 hours; this keeps scripts in step with the page).
    const response = await fetch(new Request(request, { cache: 'no-cache' }));
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
  // Other hosts (CDNs, Supabase, ...) are never intercepted.
});
