// isolate.js: makes the page cross-origin isolated on a server that cannot
// send the COOP and COEP headers (for example GitHub Pages), so that the
// slice has threads. It installs a service worker (isolate-sw.js) that
// adds the headers to each answer of the server, and loads the page again
// once, through that worker.
//
// A server that sends the headers needs neither file: the page is isolated
// at the start, and this script does nothing. ?threads=0 turns it off.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

(() => {
  if (window.crossOriginIsolated || !window.isSecureContext || !("serviceWorker" in navigator)) return;
  if (new URLSearchParams(location.search).get("threads") === "0") return;
  // The worker controls the page, and the page is not isolated: the
  // browser does not support it. The page stays as it is.
  if (navigator.serviceWorker.controller) return;
  const again = () => {
    // Once in a session: a load with no service worker (Shift+reload)
    // must not start a loop.
    try {
      if (sessionStorage.getItem("zslice.isolate")) return;
      sessionStorage.setItem("zslice.isolate", "1");
    } catch {
      return;
    }
    location.reload();
  };
  navigator.serviceWorker.addEventListener("controllerchange", again);
  navigator.serviceWorker.register("isolate-sw.js").then((reg) => {
    if (reg.active && !navigator.serviceWorker.controller) again();
  }).catch(() => {});
})();
