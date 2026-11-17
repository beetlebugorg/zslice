// isolate-sw.js: the service worker of isolate.js. It adds the headers for
// cross-origin isolation to each answer. It keeps no cache and sends
// nothing to another server: each request goes to the network as the page
// sent it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
  const req = e.request;
  // A request that the browser can answer only from its cache.
  if (req.cache === "only-if-cached" && req.mode !== "same-origin") return;
  e.respondWith(fetch(req).then((res) => {
    // An opaque answer has no headers to change.
    if (res.status === 0) return res;
    const headers = new Headers(res.headers);
    headers.set("Cross-Origin-Opener-Policy", "same-origin");
    headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  }));
});
