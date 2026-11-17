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
function fetchOptions(url, init) {
  const opts = { ...init, mode: "cors", credentials: "omit", cache: "no-store" };
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
  const why = cross
    ? " Check the address, that the printer allows this page (CORS: printdeck allows zslice.beetlebug.org; OctoPrint: Settings › API › Allow Cross Origin Requests; Moonraker: cors_domains), and that the browser may reach the local network."
    : " Check the address.";
  return `The printer did not answer (${e.message}).${why}`;
}

// Sends `bytes` (the G-code) as `filename`; print: start the print.
// Returns { ok, message }.
export async function send(printer, filename, bytes, print) {
  if (!printer?.url || !printer.kind || printer.kind === "none") return { ok: false, message: "This printer has no connection." };
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: "application/octet-stream" }), filename);
  form.append("print", print ? "true" : "false");
  const path = printer.kind === "moonraker" ? "/server/files/upload" : "/api/files/local";
  let r;
  try {
    r = await fetch(join(printer.url, path), fetchOptions(printer.url, { method: "POST", headers: headers(printer), body: form }));
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

// A test of the connection: the version of the API. Returns { ok, message }.
export async function test(printer) {
  if (!printer?.url) return { ok: false, message: "No address." };
  const path = printer.kind === "moonraker" ? "/server/info" : "/api/version";
  try {
    const r = await fetch(join(printer.url, path), fetchOptions(printer.url, { headers: headers(printer) }));
    if (r.status === 401 || r.status === 403) return { ok: false, message: "The printer refused the API key." };
    if (!r.ok) return { ok: false, message: `The printer answered ${r.status}.` };
    const j = await r.json();
    const v = j.server ?? j.text ?? j.result?.moonraker_version ?? j.result?.klippy_state ?? "";
    return { ok: true, message: `Connected${v ? `: ${v}` : ""}.` };
  } catch (e) {
    return { ok: false, message: explain(e, printer) };
  }
}
