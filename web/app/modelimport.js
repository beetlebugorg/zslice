// modelimport.js: import a model from a model page or a ZIP file.
//
// The rules and the list are in the core (zs_import_* in zslice.h, and
// docs/internals/model-import.md), so the web app lists, groups, and
// checks the files as the other apps do.
//
// zslice calls no API of a site, in any app: the API of Printables is
// private, and the terms of Prusa forbid the automated extraction of
// content; the API of Thingiverse needs an app token. For a model page
// the web app shows the text of the core (zs_import_page_text) and opens
// the page. The user downloads the ZIP file of the model ("Download
// all"), and drops it on zslice. The list comes from the ZIP file.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// enum zs_import_result, enum zs_import_site, and enum zs_import_kind.
export const IMPORT = {
  ok: 0, notAPage: 1, noApi: 2, badAnswer: 3, noFiles: 5,
  nothingChecked: 6, tooMany: 7, tooLarge: 8, notZip: 10,
};
export const SITE = { none: 0, printables: 1, thingiverse: 2 };
export const KIND = { other: 0, stl: 1, threemf: 2, step: 3, obj: 4 };

// The layout of the structs in wasm32 memory. zs_import_limits gives the
// sizes, and the constructor checks them.
const PAGE = { site: 0, id: 4, url: 36, size: 164 };
const FILE = { name: 0, folder: 4, note: 8, kindLabel: 12, size: 16, kind: 24, canLoad: 28, checked: 32, plates: 36, bytes: 40 };
const INFO = { site: 0, title: 4, author: 8, license: 12, pageUrl: 16, note: 20, bytes: 24 };

// The calls of the core with a Wasm (wasm.js) of the page.
export class ImportRules {
  constructor(wasm) {
    this.w = wasm;
    const cell = wasm.alloc(32);
    wasm.x.zs_import_limits(cell, cell + 8, cell + 16);
    this.maxFiles = wasm.u32(cell);
    const pageSize = wasm.u32(cell + 8);
    const fileSize = wasm.u32(cell + 16);
    wasm.free(cell, 32);
    if (pageSize !== PAGE.size || fileSize !== FILE.bytes) throw new Error("zslice: the import structs do not match");
  }

  message(code) {
    return this.w.cstr(this.w.x.zs_import_message(code));
  }

  // The text for a model page of a site: it names the site, and says how
  // to get the ZIP file of the model.
  pageText(site) {
    return this.w.cstr(this.w.x.zs_import_page_text(site));
  }

  // Reads the address of a model page: { ok, site, id, url } or
  // { ok: false, why }.
  page(text) {
    const w = this.w;
    const p = w.alloc(PAGE.size);
    try {
      const code = w.withString(String(text ?? "").trim(), (t) => w.x.zs_import_page_check(t, p));
      if (code !== IMPORT.ok) return { ok: false, code, why: this.message(code) };
      return { ok: true, site: w.i32(p + PAGE.site), id: w.cstr(p + PAGE.id), url: w.cstr(p + PAGE.url) };
    } finally {
      w.free(p, PAGE.size);
    }
  }

  // Lists the files of a ZIP file. Returns an ImportList, or throws an
  // Error with the text for the user.
  listZip(bytes) {
    const w = this.w;
    const cell = w.alloc(4);
    try {
      const code = w.withBytes(bytes, (p, n) => w.x.zs_import_list_zip(p, n, cell));
      if (code !== IMPORT.ok) throw new Error(this.message(code));
      return new ImportList(this, w.u32(cell), bytes);
    } finally {
      w.free(cell, 4);
    }
  }
}

// A list of the core (zs_import_list). Call free() when done.
export class ImportList {
  constructor(rules, ptr, zip) {
    this.rules = rules;
    this.w = rules.w;
    this.ptr = ptr;
    this.zip = zip;
  }

  free() {
    if (this.ptr) this.w.x.zs_import_list_free(this.ptr);
    this.ptr = 0;
  }

  info() {
    const w = this.w;
    const p = w.alloc(INFO.bytes);
    try {
      w.x.zs_import_list_info(this.ptr, p);
      const s = (o) => w.cstr(w.u32(p + o));
      return { site: w.i32(p + INFO.site), title: s(INFO.title), author: s(INFO.author), license: s(INFO.license), pageUrl: s(INFO.pageUrl), note: s(INFO.note) };
    } finally {
      w.free(p, INFO.bytes);
    }
  }

  // The files: { index, name, folder, note, kindLabel, size,
  // kind, canLoad, checked, plates }.
  files() {
    const w = this.w;
    const n = w.x.zs_import_count(this.ptr);
    const p = w.alloc(FILE.bytes);
    const out = [];
    try {
      for (let i = 0; i < n; i++) {
        w.x.zs_import_file_get(this.ptr, i, p);
        const s = (o) => w.cstr(w.u32(p + o));
        out.push({
          index: i,
          name: s(FILE.name),
          folder: s(FILE.folder),
          note: s(FILE.note),
          kindLabel: s(FILE.kindLabel),
          size: Number(w.dv.getBigUint64(p + FILE.size, true)),
          kind: w.i32(p + FILE.kind),
          canLoad: w.i32(p + FILE.canLoad) !== 0,
          checked: w.i32(p + FILE.checked) !== 0,
          plates: w.i32(p + FILE.plates),
        });
      }
    } finally {
      w.free(p, FILE.bytes);
    }
    return out;
  }

  check(i, on) {
    this.w.x.zs_import_check(this.ptr, i, on ? 1 : 0);
  }

  // { code, files, bytes, why }: code IMPORT.ok if the load can start.
  ready() {
    const w = this.w;
    const cell = w.alloc(16);
    try {
      const code = w.x.zs_import_ready(this.ptr, cell, cell + 8);
      return { code, files: w.u32(cell), bytes: Number(w.dv.getBigUint64(cell + 8, true)), why: code === IMPORT.ok ? "" : this.rules.message(code) };
    } finally {
      w.free(cell, 16);
    }
  }

  // The bytes of file i of the ZIP file.
  zipFile(i) {
    const w = this.w;
    const cell = w.alloc(8);
    try {
      const code = w.withBytes(this.zip, (p, n) => w.x.zs_import_zip_file(this.ptr, p, n, i, cell, cell + 4));
      if (code !== IMPORT.ok) throw new Error(this.rules.message(code));
      const ptr = w.u32(cell);
      const len = w.u32(cell + 4);
      const bytes = w.u8.slice(ptr, ptr + len);
      w.x.zs_buffer_free(ptr, len);
      return bytes;
    } finally {
      w.free(cell, 8);
    }
  }
}

function el(tag, props = {}, ...children) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...children);
  return e;
}

function formatSize(n) {
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(1)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(0)} kB`;
  return `${n} bytes`;
}

// The dialog for the address of a model page. zslice reads no list from
// a site, so the dialog says how to get the ZIP file, and opens the page.
export function askImportPage(rules, text = "") {
  const d = el("dialog", { className: "printers-dialog pair-dialog import-dialog" });
  const title = el("h3", { textContent: "Import a model" });
  const lead = el("p", { className: "pair-text", textContent: "Paste the address of a model page on Printables or Thingiverse." });
  const input = el("input", { type: "url", placeholder: "https://www.printables.com/model/…", value: text, spellcheck: false });
  input.style.width = "100%";
  const note = el("p", { className: "dim pair-count", textContent: "" });
  const cancel = el("button", { textContent: "Cancel" });
  const openPage = el("button", { className: "suggested", textContent: "Open the page" });
  const go = el("button", { className: "suggested", textContent: "Continue" });
  openPage.hidden = true;
  const bar = el("div", { className: "pair-actions" }, cancel, openPage, go);
  d.append(title, lead, input, note, bar);
  document.body.append(d);
  let page = null;
  const close = () => {
    d.close();
    d.remove();
  };
  cancel.onclick = close;
  d.oncancel = (e) => {
    e.preventDefault();
    close();
  };
  const read = () => {
    page = rules.page(input.value);
    note.classList.toggle("error", !page.ok);
    if (!page.ok) {
      note.textContent = page.why;
      openPage.hidden = true;
      go.hidden = false;
      return;
    }
    note.textContent = rules.pageText(page.site);
    openPage.hidden = false;
    go.hidden = true;
  };
  go.onclick = read;
  input.onkeydown = (e) => {
    if (e.key === "Enter") read();
  };
  input.oninput = () => {
    openPage.hidden = true;
    go.hidden = false;
  };
  openPage.onclick = () => {
    window.open(page.url, "_blank", "noopener,noreferrer");
    close();
  };
  d.showModal();
  if (text) read();
  input.focus();
  return d;
}

// The list of the files of a ZIP file, with a check box for each file
// that loads. load(files) gets [{ name, bytes }] of the checked files;
// it puts them on plates. The dialog never starts a print.
export function showImportList(list, name, load) {
  const info = list.info();
  const d = el("dialog", { className: "printers-dialog pair-dialog import-dialog" });
  const title = el("h3", { textContent: info.title || name });
  const sub = el("p", { className: "dim pair-count", textContent: "The files of the ZIP file" });
  const note = el("p", { className: "pair-text", textContent: info.note });
  note.hidden = !info.note;
  const rows = el("div", { className: "import-rows" });
  rows.style.maxHeight = "50vh";
  rows.style.overflowY = "auto";
  let group = null;
  for (const f of list.files()) {
    if (f.kindLabel !== group) {
      group = f.kindLabel;
      rows.append(el("h4", { textContent: group }));
    }
    const check = el("input", { type: "checkbox", checked: f.checked, disabled: !f.canLoad });
    check.onchange = () => {
      list.check(f.index, check.checked);
      sum();
    };
    const parts = [];
    if (f.kind !== KIND.other) parts.push(f.kindLabel);
    if (f.size > 0) parts.push(formatSize(f.size));
    if (f.plates > 1) parts.push(`${f.plates} plates`);
    let detail = parts.join(", ");
    if (f.folder) detail += `. In the folder ${f.folder}`;
    if (f.note) detail += `${detail ? ". " : ""}${f.note}`;
    const text = el("span", {}, el("span", { textContent: f.name, className: f.canLoad ? "" : "dim" }), el("br"), el("small", { className: "dim", textContent: detail }));
    const row = el("label", { className: "import-row" }, check, text);
    row.style.display = "flex";
    row.style.gap = "10px";
    row.style.alignItems = "center";
    row.style.margin = "4px 0";
    rows.append(row);
  }
  const status = el("p", { className: "dim pair-count" });
  const cancel = el("button", { textContent: "Cancel" });
  const go = el("button", { className: "suggested", textContent: "Load" });
  const bar = el("div", { className: "pair-actions" }, cancel, go);
  d.append(title, sub, note, rows, status, bar);
  document.body.append(d);
  const sum = () => {
    const r = list.ready();
    go.disabled = r.code !== IMPORT.ok;
    status.classList.toggle("error", r.code !== IMPORT.ok && r.code !== IMPORT.nothingChecked);
    status.textContent = r.code === IMPORT.ok
      ? `${r.files} ${r.files === 1 ? "file" : "files"}, ${formatSize(r.bytes)}. zslice puts their parts on plates. It does not start a print.`
      : r.why;
  };
  const close = () => {
    list.free();
    d.close();
    d.remove();
  };
  cancel.onclick = close;
  d.oncancel = (e) => {
    e.preventDefault();
    close();
  };
  go.onclick = async () => {
    go.disabled = true;
    const files = [];
    const errors = [];
    for (const f of list.files()) {
      if (!f.checked) continue;
      try {
        files.push({ name: f.name, bytes: list.zipFile(f.index) });
      } catch (e) {
        errors.push(`${f.name}: ${e.message}`);
      }
    }
    close();
    await load(files, errors);
  };
  sum();
  d.showModal();
  // Enter must not start a load that the user did not read.
  cancel.focus();
  return d;
}
