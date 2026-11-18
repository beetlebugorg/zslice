// link.js: send G-code to a printer from the browser (linux/src/net/
// printer-link.c, zg_link_send).
//
// printdeck and OctoPrint: the OctoPrint API, POST /api/files/local.
// Moonraker (Klipper): POST /server/files/upload. Both take a multipart form
// with the file and print=true or false, and the API key in X-Api-Key.
//
// A printer on the LAN and a page from another site (zslice.beetlebug.org):
// - The printer must allow the page with CORS: printdeck does it for
//   zslice.beetlebug.org (WEB_ORIGINS), OctoPrint has "Allow Cross Origin
//   Requests" in its API settings, and Moonraker has cors_domains.
// - Chrome asks the user once to let the page reach the local network
//   (Local Network Access). The fetch says that it goes to the local
//   network (targetAddressSpace), which also lets an https page reach an
//   http printer.
// A page that the printer serves itself (the zslice app on a printdeck)
// needs neither.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { printerStatusPaths, readPrinterStatus } from "./format.js";

export const KINDS = {
  none: "None (export a file)",
  printdeck: "printdeck",
  octoprint: "OctoPrint",
  moonraker: "Moonraker (Klipper)",
};

function join(base, path) {
  return base.replace(/\/+$/, "") + path;
}

// The options of a fetch to the printer at `url`. An https page that
// calls an http printer must name the address space of the printer
// (Chrome's Local Network Access), and the name must match the real one:
// "loopback" for this computer, "local" for the LAN. Other calls leave it
// out, and Chrome finds it.
//
// The fetch sends cookies only to the origin of the page (credentials
// "same-origin"). A printdeck that serves the app takes its login cookie
// in place of an API key. A printer on another origin gets no cookies.
function fetchOptions(url, init) {
  const opts = { ...init, mode: "cors", credentials: "same-origin", cache: "no-store" };
  try {
    const u = new URL(url, location.href);
    if (u.origin !== location.origin && location.protocol === "https:" && u.protocol === "http:") {
      const h = u.hostname.replace(/^\[|\]$/g, "");
      opts.targetAddressSpace = h === "localhost" || h === "::1" || h.startsWith("127.") ? "loopback" : "local";
    }
  } catch {
    // A bad address fails in the fetch, with its own message.
  }
  return opts;
}

// The addresses to try for a printer, best first. A printdeck with a
// certificate has an https address too (printer.https, from its
// /slicer/printer.json): https://<host>.d.printdeck.beetlebug.org. The app
// tries it first. An https page never tries an http address of another
// origin: the browser blocks it (mixed content), except Chrome with Local
// Network Access, so the http address stays last for Chrome.
function addresses(printer) {
  const out = [];
  const seen = new Set();
  const add = (u) => {
    if (u && !seen.has(u)) {
      seen.add(u);
      out.push(u);
    }
  };
  const last = worked.get(printer.name);
  if (last && (last === printer.https || last === printer.url)) add(last);
  add(printer.https);
  add(printer.url);
  return out;
}

// The address that answered last, for each printer, in this page.
const worked = new Map();

// A fetch of `path` on the printer: each address in turn. A network
// failure (no DNS answer when a router blocks the public name of a LAN
// address, a TLS failure, a timeout) goes on to the next address with no
// error. An answer of the printer, of any status, ends it. Throws the
// error of the last address.
async function request(printer, path, init = {}, timeout = 0) {
  const list = addresses(printer);
  let err = new Error("No address.");
  for (let k = 0; k < list.length; k++) {
    const base = list[k];
    // A short wait for an address with a next one to try.
    const ms = timeout || (k < list.length - 1 ? 4000 : 0);
    const ctrl = ms ? new AbortController() : null;
    const timer = ctrl ? setTimeout(() => ctrl.abort(), ms) : 0;
    try {
      const r = await fetch(join(base, path), fetchOptions(base, ctrl ? { ...init, signal: ctrl.signal } : init));
      worked.set(printer.name, base);
      return r;
    } catch (e) {
      err = e;
      // A form body can be sent again: FormData and strings stay.
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
  throw err;
}

function headers(printer) {
  const h = {};
  if (printer.apiKey) h["X-Api-Key"] = printer.apiKey;
  return h;
}

// A failed fetch in words: a fetch error of a browser says little.
function explain(e, printer) {
  const cross = (() => {
    try {
      return new URL(printer.url, location.href).origin !== location.origin;
    } catch {
      return false;
    }
  })();
  // An https page and an http printer: the browser blocks the request
  // (mixed content) before it leaves, so CORS is not the cause.
  let mixed = false;
  try {
    mixed = location.protocol === "https:" && new URL(printer.url, location.href).protocol === "http:";
  } catch {
    // Not a URL: the text below.
  }
  if (mixed) {
    const deck = (() => {
      try {
        return new URL("/slicer/", printer.url).href;
      } catch {
        return "";
      }
    })();
    const https = printer.https ? ` The secure address (${printer.https}) did not answer either: a router or a DNS filter (for example Pi-hole) that blocks public names of local addresses (DNS rebinding protection) stops it.` : "";
    return `The browser blocked the request (${e.message}).${https} This page is https and the printer is http, and some browsers (Firefox, Safari) block that. Open zslice from the printer instead${deck ? `: ${deck} (printdeck has it)` : ""}, or give the printer an https address.`;
  }
  const why = cross
    ? " Check the address, that the printer allows this page (CORS: printdeck allows zslice.beetlebug.org; OctoPrint: Settings › API › Allow Cross Origin Requests; Moonraker: cors_domains), and that the browser may reach the local network."
    : " Check the address.";
  return `The printer did not answer (${e.message}).${why}`;
}

// Sends `bytes` (the G-code) as `filename`; print: start the print.
// Returns { ok, message }.
export async function send(printer, filename, bytes, print) {
  if ((!printer?.url && !printer?.https) || !printer.kind || printer.kind === "none") return { ok: false, message: "This printer has no connection." };
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: "application/octet-stream" }), filename);
  form.append("print", print ? "true" : "false");
  const path = printer.kind === "moonraker" ? "/server/files/upload" : "/api/files/local";
  let r;
  try {
    // No time limit on the last try: a large file takes time.
    r = await request(printer, path, { method: "POST", headers: headers(printer), body: form });
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
  if (r.status === 401 || r.status === 403) return { ok: false, message: "The printer refused the API key." };
  if (!r.ok) {
    let text = "";
    try {
      text = (await r.text()).slice(0, 200);
    } catch {
      // No text.
    }
    return { ok: false, message: `The printer answered ${r.status}${text ? `: ${text}` : ""}.` };
  }
  const where = KINDS[printer.kind] ?? printer.kind;
  if (printer.kind === "printdeck" && print) return { ok: true, message: `Sent to ${printer.name}. Press Print on its screen to start.` };
  return { ok: true, message: print ? `Sent to ${printer.name} (${where}); the print starts.` : `Uploaded to ${printer.name} (${where}).` };
}

// Asks the printer for an API key with the App Keys flow of OctoPrint
// (printdeck and OctoPrint): the printer asks its user "Allow zslice?" (on
// the touch screen of a printdeck, in the web page of OctoPrint), and the
// app gets a key of its own after "Allow". wait(seconds): called while the
// user decides. Returns { ok, key, message }. Moonraker has no such flow.
export async function requestKey(printer, wait = () => {}) {
  if (!printer?.url && !printer?.https) return { ok: false, message: "No address." };
  if (printer.kind === "moonraker") return { ok: false, message: "Moonraker gives no API keys this way: it needs none, or the key of its config." };
  const base = "/plugin/appkeys/request";
  let token;
  try {
    const r = await request(printer, base, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ app: "zslice" }),
    });
    if (r.status === 404) return { ok: false, message: "The printer does not give keys to apps (App Keys is off or missing)." };
    if (!r.ok) return { ok: false, message: `The printer answered ${r.status}.` };
    token = (await r.json()).app_token;
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
  if (!token) return { ok: false, message: "The printer gave no request token." };
  // The printer keeps a request for 2 minutes.
  const t0 = performance.now();
  while (performance.now() - t0 < 125000) {
    wait(Math.round((performance.now() - t0) / 1000));
    await new Promise((res) => setTimeout(res, 1000));
    let r;
    try {
      r = await request(printer, `${base}/${encodeURIComponent(token)}`);
    } catch (e) {
      return { ok: false, message: explain(e, printer) };
    }
    if (r.status === 202) continue;
    if (r.status === 404) return { ok: false, message: "The printer did not allow it (Deny), or the request waited too long." };
    if (!r.ok) return { ok: false, message: `The printer answered ${r.status}.` };
    const key = (await r.json()).api_key;
    if (!key) return { ok: false, message: "The printer gave no key." };
    return { ok: true, key, message: "The printer gave zslice a key." };
  }
  return { ok: false, message: "No answer on the printer in 2 minutes." };
}

// The status of the printer (its state, job, bed, nozzle, and rolls), read
// by the core from the replies of its API. Returns { ok, status, message }.
export async function status(printer) {
  if (!printer?.url && !printer?.https) return { ok: false, message: "No address." };
  const paths = printerStatusPaths(printer.kind);
  if (paths.length === 0) return { ok: false, message: "This kind of printer gives no status." };
  const replies = [];
  try {
    for (const [k, path] of paths.entries()) {
      const r = await request(printer, path, { headers: headers(printer) });
      if (r.status === 401 || r.status === 403) return { ok: false, message: "The printer refused the API key." };
      if (!r.ok) {
        if (k === 0) return { ok: false, message: `The printer answered ${r.status}.` };
        continue;
      }
      replies.push([path, await r.text()]);
    }
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
  const st = readPrinterStatus(printer.kind, replies);
  return st ? { ok: true, status: st, message: statusText(st) } : { ok: false, message: "The status did not read." };
}

// The status in words: "Printing Slate frame, 50 %, 1 h 5 min left".
export function statusText(st) {
  const parts = [st.state || "Connected"];
  if (st.job) {
    let j = st.job;
    if (st.progress > 0) j += `, ${Math.round(st.progress * 100)} %`;
    if (st.timeLeft > 0) {
      const m = Math.round(st.timeLeft / 60);
      j += `, ${m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`} left`;
    }
    parts.push(j);
  }
  if (st.spool?.name) parts.push(`${st.spool.name}${st.material ? ` (${st.material})` : ""}${st.spool.left > 0 ? `, ${Math.round(st.spool.left)} g left` : ""}`);
  else if (st.material) parts.push(st.material);
  return parts.join(" · ");
}

// A test of the connection: the version of the API. Returns { ok, message }.
export async function test(printer) {
  if (!printer?.url && !printer?.https) return { ok: false, message: "No address." };
  const path = printer.kind === "moonraker" ? "/server/info" : "/api/version";
  try {
    const r = await request(printer, path, { headers: headers(printer) });
    if (r.status === 401 || r.status === 403) return { ok: false, message: "The printer refused the API key." };
    if (!r.ok) return { ok: false, message: `The printer answered ${r.status}.` };
    const j = await r.json();
    const v = j.server ?? j.text ?? j.result?.moonraker_version ?? j.result?.klippy_state ?? "";
    const st = await status(printer);
    return { ok: true, message: `Connected${v ? `: ${v}` : ""}.${st.ok ? ` ${st.message}.` : ""}` };
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
}
