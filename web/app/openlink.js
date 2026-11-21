// openlink.js: a link that opens a model in the web app.
//
// A model site links to a slicer with zslice://open?file=<URL> (the form
// of prusaslicer://open?file=). A web page can register only a scheme that
// starts with "web+", so the page registers web+zslice:// with
// navigator.registerProtocolHandler, and the browser opens
// /?open=<the link>. A zslice:// link cannot reach a web page. The page
// also takes a plain https URL: /?open=https://.../part.stl.
//
// The rules are the rules of the core (zs_link_* in zslice.h, and
// docs/internals/open-links.md), so the web app accepts and refuses the
// same links as the other apps. The page asks before the download.
//
// What a browser does not let a page do:
// - It does not tell the page the address of a host, so the page cannot
//   check the address after DNS. The browser blocks or asks before a
//   public page reaches a local address (Local Network Access).
// - It follows redirects by itself. The page checks the last URL.
// - It reads a file of another site only if the site sends CORS headers.
//   Without them the fetch fails, and the dialog offers to download the
//   file, so that the user can open it by hand.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// enum zs_link_result.
export const LINK = {
  ok: 0, notALink: 1, notPublic: 2, localAddress: 3, notAModel: 4, project: 5,
  tooLarge: 6, webPage: 7, tooManyRedirects: 8, badRedirect: 9,
};

// The fields of struct zs_link: url, host, name.
const URL_MAX = 12304;
const HOST_MAX = 256;

const enc = new TextEncoder();

// An error of a download. cors: the browser did not let the page read the
// file (or the network failed), so a download by hand can work.
export class LinkError extends Error {
  constructor(message, cors = false) {
    super(message);
    this.cors = cors;
  }
}

// The checks of the core, with a Wasm (wasm.js) of the page.
export class LinkRules {
  constructor(wasm) {
    this.w = wasm;
    const x = wasm.x;
    const cell = wasm.alloc(16);
    x.zs_link_limits(cell, cell + 8, cell + 12);
    this.maxBytes = Number(wasm.dv.getBigUint64(cell, true));
    this.maxRedirects = wasm.i32(cell + 8);
    this.size = wasm.u32(cell + 12);
    wasm.free(cell, 16);
  }

  message(code) {
    return this.w.cstr(this.w.x.zs_link_message(code));
  }

  // Calls fn(ptr) with a zs_link in wasm memory that holds `link` (or
  // zeros), and returns { code, link } with the fields after the call.
  withLink(link, fn) {
    const w = this.w;
    const p = w.alloc(this.size);
    w.u8.fill(0, p, p + this.size);
    if (link) {
      w.u8.set(enc.encode(link.url).subarray(0, URL_MAX - 1), p);
      w.u8.set(enc.encode(link.host).subarray(0, HOST_MAX - 1), p + URL_MAX);
      w.u8.set(enc.encode(link.name ?? "").subarray(0, this.size - URL_MAX - HOST_MAX - 1), p + URL_MAX + HOST_MAX);
    }
    try {
      const code = fn(p);
      return {
        code,
        link: { url: w.cstr(p), host: w.cstr(p + URL_MAX), name: w.cstr(p + URL_MAX + HOST_MAX) },
      };
    } finally {
      w.free(p, this.size);
    }
  }

  // Reads the ?open= value: a web+zslice:// or zslice:// link, or a plain
  // https URL. Returns { ok, url, host, name } or { ok: false, why }.
  check(text) {
    const s = String(text ?? "").trim();
    const isLink = /^(web\+)?zslice:/i.test(s);
    const r = this.w.withString(s, (t) => this.withLink(null, (p) => (isLink ? this.w.x.zs_link_check(t, p) : this.w.x.zs_link_check_url(t, p))));
    if (r.code !== LINK.ok) return { ok: false, code: r.code, why: this.message(r.code) };
    return { ok: true, ...r.link };
  }

  // Checks the head of an answer. length: -1 if none.
  checkReply(contentType, length) {
    return this.w.withString(contentType ?? "", (t) => this.w.x.zs_link_check_reply(t, BigInt(length)));
  }

  // The name of the download: { code, name }.
  fileName(disposition, link) {
    const r = this.w.withString(disposition ?? "", (d) => this.withLink(link, (p) => this.w.x.zs_link_file_name(d, p)));
    return { code: r.code, name: r.link.name };
  }

  // True for a zslice project (zs_project_file_is).
  isProject(bytes) {
    return this.w.withBytes(bytes, (p, n) => this.w.x.zs_project_file_is(p, n)) !== 0;
  }
}

// Downloads the file of a checked link. onProgress(fraction) comes when
// the answer has a length. fetchFn: fetch, or a stub in a test. Returns
// { bytes, name }, or throws a LinkError.
export async function downloadModel(rules, link, { onProgress = null, signal = null, fetchFn = globalThis.fetch } = {}) {
  let r;
  try {
    r = await fetchFn(link.url, {
      // No cookie, no key, and no referrer go to the site.
      credentials: "omit",
      referrerPolicy: "no-referrer",
      cache: "no-store",
      mode: "cors",
      redirect: "follow",
      signal,
    });
  } catch (e) {
    if (e?.name === "AbortError") throw e;
    throw new LinkError(
      `The browser did not let zslice read the file. ${link.host} does not allow other web pages to read its files (CORS), or the network failed.`,
      true,
    );
  }
  // The browser followed the redirects. The last URL must pass too.
  let at = link;
  if (r.url && r.url !== link.url) {
    const last = rules.check(r.url);
    if (!last.ok) throw new LinkError(rules.message(LINK.badRedirect));
    at = { ...last, name: link.name };
  }
  if (!r.ok) throw new LinkError(`The site answered with error ${r.status}.`);
  const lengthText = r.headers.get("content-length");
  const total = lengthText ? Number(lengthText) : -1;
  let code = rules.checkReply(r.headers.get("content-type"), Number.isFinite(total) ? total : -1);
  if (code !== LINK.ok) throw new LinkError(rules.message(code));
  // A site shows Content-Disposition to the page only if it exposes it.
  const named = rules.fileName(r.headers.get("content-disposition"), at);
  if (named.code !== LINK.ok) throw new LinkError(rules.message(named.code));
  const parts = [];
  let size = 0;
  const reader = r.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > rules.maxBytes) {
      reader.cancel().catch(() => {});
      throw new LinkError(rules.message(LINK.tooLarge));
    }
    parts.push(value);
    if (onProgress && total > 0) onProgress(Math.min(1, size / total));
  }
  const bytes = new Uint8Array(size);
  let o = 0;
  for (const p of parts) {
    bytes.set(p, o);
    o += p.length;
  }
  if (/\.3mf$/i.test(named.name) && rules.isProject(bytes)) throw new LinkError(rules.message(LINK.project));
  return { bytes, name: named.name };
}

// The address that a model site can use for the web app: the plain form,
// for a site that does not know web+zslice.
export function webAppLink(fileUrl, origin = "https://zslice.beetlebug.org") {
  return `${origin}/?open=${encodeURIComponent(fileUrl)}`;
}

// Registers web+zslice:// links for this page. Returns a text for the
// user.
export function registerLinks() {
  if (!globalThis.isSecureContext || !navigator.registerProtocolHandler) {
    return "This browser cannot send links to a web page. Use the link form https://zslice.beetlebug.org/?open=<file URL>.";
  }
  try {
    navigator.registerProtocolHandler("web+zslice", `${location.origin}${location.pathname}?open=%s`);
    return "The browser asks if zslice can open web+zslice links. Allow it.";
  } catch (e) {
    return `The browser refused: ${e.message}`;
  }
}
