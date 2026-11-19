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

import { printerCameraPaths, printerStatusPaths, readPrinterStatus } from "./format.js";
import { publicKey, signGcode } from "./signing.js";

export const KINDS = {
  none: "None (export a file)",
  printdeck: "printdeck",
  octoprint: "OctoPrint",
  moonraker: "Moonraker (Klipper)",
};

// The trust of a printer, for the printer list: printdeck can check the
// signature of each print (Settings › Signed prints on the deck).
// OctoPrint and Moonraker check no signatures. The browser checks the
// certificate of an https printer; a page has no access to it, so the app
// cannot pin it (the GTK and macOS apps do).
export function trustText(printer) {
  switch (printer?.kind) {
    case "printdeck":
      return printer.https || /^https:/i.test(printer.url ?? "")
        ? "zslice signs each print. Turn on Settings › Signed prints on the deck to refuse prints from other apps."
        : "zslice signs each print. The address is http, so the browser cannot verify the deck: use its https address.";
    case "octoprint":
    case "moonraker":
      return "Not verified: this printer does not check the signatures of prints.";
    default:
      return "";
  }
}

function join(base, path) {
  return base.replace(/\/+$/, "") + path;
}

// An http or https address from outside (a printer or a deck), or "". A
// javascript: or data: address must not open or load.
export function webAddress(u) {
  try {
    const p = new URL(u).protocol;
    return p === "http:" || p === "https:" ? u : "";
  } catch {
    return "";
  }
}

// A printer name from outside that can be a key of the printer store: a
// text that is not a name of Object.prototype ("__proto__" would change
// the prototype of the store).
export function plainName(name) {
  return typeof name === "string" && name.length > 0 && !(name in Object.prototype);
}

// The address of a printer under a deck: the base of the deck and the
// path that the deck gives ("/printers/<id>"), or "" for a path that could
// leave the deck ("@other.host/", "//other.host/", a full address).
export function deckAddress(base, path) {
  if (!base || typeof path !== "string" || path.startsWith("//") || (path !== "" && !/^\/[A-Za-z0-9._~/-]*$/.test(path))) return "";
  const url = base.replace(/\/+$/, "") + path;
  try {
    return new URL(url).origin === new URL(base).origin ? url : "";
  } catch {
    return "";
  }
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
//
// A request with the API key follows no redirect (redirect "error"): a
// fetch keeps X-Api-Key on a redirect, so a printer (or a device at its
// address) could send the key to another host.
export function fetchOptions(url, init) {
  const keyed = Object.keys(init?.headers ?? {}).some((h) => h.toLowerCase() === "x-api-key");
  const opts = { ...init, mode: "cors", credentials: "same-origin", cache: "no-store", redirect: keyed ? "error" : "follow" };
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
  // A deck that drives more printers: the address must lead to the
  // printer that the user picked. A print once went to the first printer
  // of a deck (the address of the deck itself) in place of another one.
  if (printer.kind === "printdeck") {
    const v = await checkDeckTarget(printer);
    if (!v.ok) return v;
  }
  // Each file that goes out has the signature of this browser (signing.js).
  bytes = await signGcode(bytes);
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
      text = (await r.text()).slice(0, 300);
      // The OctoPrint API has the reason in {"error": "..."}: printdeck
      // says "Rejected: not signed by a trusted slicer" there.
      text = JSON.parse(text).error ?? text;
    } catch {
      // No text, or no JSON.
    }
    return { ok: false, message: `The printer answered ${r.status}${text ? `: ${text}` : ""}.` };
  }
  const where = KINDS[printer.kind] ?? printer.kind;
  // A printdeck with "Start prints from the slicer" off asks on its screen:
  // its reply has effectivePrint false, and the print waits for a press of
  // Print on the deck.
  let started = print;
  if (print && printer.kind === "printdeck") {
    try {
      started = (await r.json()).effectivePrint !== false;
    } catch {
      // No JSON: as asked.
    }
    if (!started) return { ok: true, message: `Sent to ${printer.name}. It waits there: press Print on the deck to start it.` };
  }
  return { ok: true, message: started ? `Sent to ${printer.name} (${where}); the print starts.` : `Uploaded to ${printer.name} (${where}).` };
}

// Asks the printer for an API key with the App Keys flow of OctoPrint
// (printdeck and OctoPrint): the printer asks its user "Allow zslice?" (on
// the touch screen of a printdeck, in the web page of OctoPrint), and the
// app gets a key of its own after "Allow". wait(seconds): called while the
// user decides. Returns { ok, key, message }. Moonraker has no such flow.
export async function requestKey(printer, wait = () => {}, signal = null) {
  if (!printer?.url && !printer?.https) return { ok: false, message: "No address." };
  if (printer.kind === "moonraker") return { ok: false, message: "Moonraker gives no API keys this way: it needs none, or the key of its config." };
  const base = "/plugin/appkeys/request";
  let token;
  try {
    // printdeck: the public key of the signatures too. The deck trusts it
    // after "Allow".
    const pub = printer.kind === "printdeck" ? await publicKey() : "";
    const r = await request(printer, base, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(pub ? { app: "zslice", public_key: pub } : { app: "zslice" }),
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
    if (signal?.aborted) return { ok: false, cancelled: true, message: "Cancelled." };
    wait(Math.round((performance.now() - t0) / 1000));
    await new Promise((res) => setTimeout(res, 1000));
    if (signal?.aborted) return { ok: false, cancelled: true, message: "Cancelled." };
    let r;
    try {
      r = await request(printer, `${base}/${encodeURIComponent(token)}`);
    } catch (e) {
      return { ok: false, message: explain(e, printer) };
    }
    if (r.status === 202) continue;
    if (r.status === 404) return { ok: false, message: "The printer did not allow it (Deny), or the request waited too long." };
    if (!r.ok) return { ok: false, message: `The printer answered ${r.status}.` };
    const j = await r.json();
    const key = j.api_key;
    if (!key) return { ok: false, message: "The printer gave no key." };
    if (j.trusted_key) return { ok: true, key, message: "The printer gave zslice a key, and trusts the prints that this browser signs." };
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

// The camera of the printer, read once (zs_printer_camera_paths): { ok,
// camera: { stream, snapshot, flipH, flipV, rotation } with absolute
// addresses, or null for no camera, message }. The addresses of OctoPrint
// and printdeck are relative to the printer; printdeck puts the API key of
// the request in them, because an <img> sends no header.
export async function camera(printer) {
  if (!printer?.url && !printer?.https) return { ok: false, message: "No address." };
  const paths = printerCameraPaths(printer.kind);
  if (paths.length === 0) return { ok: false, message: "This kind of printer gives no camera to a web page." };
  const replies = [];
  let base = "";
  try {
    for (const path of paths) {
      const r = await request(printer, path, { headers: headers(printer) });
      if (r.status === 401 || r.status === 403) return { ok: false, message: "The printer refused the API key." };
      if (!r.ok) continue;
      base = worked.get(printer.name) ?? printer.url;
      replies.push([path, await r.text()]);
    }
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
  const st = readPrinterStatus(printer.kind, replies);
  const c = st?.camera;
  const abs = (u) => {
    if (!u) return "";
    try {
      return new URL(u, base.replace(/\/*$/, "/")).href;
    } catch {
      return "";
    }
  };
  const out = c ? { ...c, stream: abs(c.stream), snapshot: abs(c.snapshot) } : null;
  return { ok: true, camera: out && (out.stream || out.snapshot) ? out : null, message: "" };
}

// The kind of the printer at an address, from the paths that answer with
// no key: /api/version of printdeck ("... (Printdeck ...)" in its text)
// and OctoPrint, and /server/info of Moonraker. Returns { ok, kind,
// message }.
export async function detectKind(url) {
  const p = { url, name: url };
  try {
    const r = await request(p, "/api/version", {}, 5000);
    if (r.ok) {
      const j = await r.json().catch(() => ({}));
      return { ok: true, kind: /printdeck/i.test(j.text ?? "") ? "printdeck" : "octoprint" };
    }
  } catch {
    // Not OctoPrint or printdeck, or out of reach: Moonraker next.
  }
  try {
    const r = await request(p, "/server/info", {}, 5000);
    if (r.ok) return { ok: true, kind: "moonraker" };
  } catch (e) {
    return { ok: false, message: explain(e, p) };
  }
  return { ok: false, message: "The printer at this address is not a printdeck, an OctoPrint, or a Moonraker printer." };
}

// The deck printer that `printer` leads to: its root (the address with no
// /printers/<id>), then the entry of /slicer/printer.json at that path.
// Not ok when the deck drives more printers and the address leads to
// another printer than this one: a path that the deck does not have, a
// name of the deck that differs, or the name of the user's printer that
// is the name of another printer of the deck. When the deck does not
// answer the list (an older deck, or one with no CORS for this page), the
// check passes: there is nothing to check against.
export async function checkDeckTarget(printer) {
  const split = (u) => {
    const m = /^(.*?)(\/printers\/[A-Za-z0-9._~-]+)?\/?$/.exec(u || "");
    return m ? [m[1], m[2] || ""] : [u || "", ""];
  };
  const [root, path] = split(printer.url || printer.https);
  const [hroot] = split(printer.https || "");
  const dp = await deckPrinters({ ...printer, url: root, https: hroot });
  if (!dp.ok || dp.printers.length < 2) return { ok: true };
  const norm = (s) => String(s ?? "").trim().toLowerCase();
  const at = dp.printers.find((q) => (q?.url || "") === path);
  if (!at) return { ok: false, message: `The deck has no printer at ${path || "its own address"}. Add the printer again from the deck (Printers, Add printer).` };
  const atName = norm(at.name);
  if (printer.deckName && norm(printer.deckName) !== atName) {
    return { ok: false, message: `This address leads to ${at.name} on the deck, not to ${printer.deckName}. Nothing was sent. Add the printer again from the deck.` };
  }
  const mine = norm(printer.name);
  const other = dp.printers.find((q) => q !== at && (norm(q?.name) === mine || norm(q?.label) === mine || mine.startsWith(norm(q?.name) + " (")));
  if (other && atName !== mine) {
    return { ok: false, message: `${printer.name} is at ${other.url} on the deck, but this printer's address leads to ${at.name}. Nothing was sent. Add ${printer.name} again from the deck (Printers, Add printer).` };
  }
  return { ok: true, model: at.model ?? "" };
}

// The printers of a printdeck (GET /slicer/printer.json with the key): a
// deck with more than one printer lists them, each with the path of its
// API under the deck ("" for the first, "/printers/<id>" for another).
// Returns { ok, name, https, printers: [{ id, name, label, color, kind,
// url }], message }.
export async function deckPrinters(printer) {
  try {
    const r = await request(printer, "/slicer/printer.json", { headers: headers(printer) });
    if (r.status === 401 || r.status === 403) return { ok: false, message: "The deck refused the key." };
    if (!r.ok) return { ok: false, message: `The deck answered ${r.status}.` };
    const j = await r.json();
    // The https address must be https: the key goes there.
    const https = typeof j.https === "string" && /^https:\/\//i.test(j.https) ? webAddress(j.https) : "";
    return { ok: true, name: j.name ?? "", https, printers: Array.isArray(j.printers) ? j.printers : [] };
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
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
