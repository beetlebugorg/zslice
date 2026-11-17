// inspector.js: the Selected page of the panel (linux/src/ui/inspector.c).
// A click on a line in the 3D or the 2D view selects it, and this page
// shows what the line is: its feature and layer, the planned speed, the
// real speed, and the flow (a click on a number tells why it is what it
// is), the support mark at the line, the settings that change it (in
// sections, with a filter), and how the values come about. All the text
// comes from the core (zs_app_inspect); the page only lays it out.
//
// The edits on this page are for the layers of the line, or for all
// layers ("Change for"). After a new slice of the same line, the page
// changes its text in place and keeps its rows, so the editor with the
// focus keeps it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { openPopover, closeMenu } from "./menus.js";
import { displayValue, sourceText } from "./format.js";

const STATS = ["planned speed", "real speed", "flow"];
const SCOPES = ["This print (all layers)", "This layer", "This layer and up", "This layer and down"];
const MARK_KINDS = ["Grid", "Tree", "Bridge pad", "Block (no support)"];
const SLOW_NOTES = [
  "",
  "This layer is short, so it prints slower to cool (filament minimum layer time). Click the real speed for more.",
  "The segments are short: the head does not reach the full speed between the corners (acceleration). Click the real speed for more.",
];

// The sections that are open, by title, for the next selection. Speed
// and Shape start open.
const sectionOpen = new Map([["Speed", true], ["Shape", true]]);
// The scope of the edits: it stays for the next selection.
let scopeMode = 0;

export class Inspector {
  // ctx: { browser (SettingsBrowser: its infos and editors),
  //        setScoped(name, value, zmin, zmax) -> Promise<error>,
  //        resetScoped(name, zmin, zmax, z), openSetting(name),
  //        copyForAi(), markSet(index, kind, r), markRemove(index) }
  constructor(root, ctx) {
    this.root = root;
    this.ctx = ctx;
    this.signature = null;
    this.info = null;
    this.rows = [];
    this.show(null);
  }

  // The z range of the edits, for the z of the line.
  scope() {
    const z = this.info?.z ?? 0;
    switch (scopeMode) {
      case 1: return [z, z];
      case 2: return [z, 1e6];
      case 3: return [-1e6, z];
      default: return [-1e6, 1e6];
    }
  }

  // While a slice runs, the numbers are old: dim them.
  setStale(on) {
    this.root.classList.toggle("stale", on);
  }

  // Shows a line (an answer of the worker op "inspect"), or the hint.
  show(info) {
    const signature = info ? `${info.title}\n${info.settings}` : "";
    this.info = info;
    if (info && signature === this.signature) {
      this.update();
      return;
    }
    this.signature = signature;
    this.build();
  }

  build() {
    const root = this.root;
    root.replaceChildren();
    this.rows = [];
    const info = this.info;
    if (!info) {
      const box = el("div", "placeholder");
      box.append(el("div", "placeholder-title", "No line selected"));
      box.append(el("div", "dim", "Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it."));
      root.append(box);
      return;
    }
    const page = el("div", "inspector");
    const head = el("div", "insp-head");
    this.title = el("div", "insp-title");
    const copy = el("button", "flat insp-copy", "Copy for AI");
    copy.title = "Copy a report of this line (what it is, why, its settings, and its G-code) to paste into an AI chat";
    copy.onclick = () => this.ctx.copyForAi();
    head.append(this.title, copy);
    page.append(head);

    // The three numbers: a click tells why.
    const stats = el("div", "insp-stats");
    this.statValues = [];
    STATS.forEach((name, i) => {
      const b = el("button", "flat insp-stat");
      b.title = "Why this value? Click for the numbers and the settings that change it.";
      const v = el("div", "value");
      b.append(v, el("div", "caption", name));
      b.onclick = () => this.showWhy(b, i);
      this.statValues.push(v);
      stats.append(b);
    });
    page.append(stats);
    this.note = el("div", "insp-note");
    page.append(this.note);

    // The support mark of the user at this line.
    this.markBox = el("div", "insp-mark");
    page.append(this.markBox);

    // Change for: all layers, or the layers of the line.
    const scopeRow = el("div", "insp-scope");
    scopeRow.append(el("span", "dim", "Change for"));
    const sel = el("select", "choice");
    SCOPES.forEach((s, i) => sel.append(new Option(s, String(i))));
    sel.value = String(scopeMode);
    sel.title = "Changes here are for this print: for all its layers, or only for the layers of the selected line.";
    sel.onchange = () => { scopeMode = Number(sel.value); };
    scopeRow.append(sel);
    page.append(scopeRow);
    page.append(el("div", "dim caption", "Changes here are for this print. Settings has the defaults of all prints."));

    const filter = el("input", "insp-filter");
    filter.type = "search";
    filter.placeholder = "Filter settings";
    filter.oninput = () => this.filter(filter.value);
    page.append(filter);

    // The settings, in sections.
    this.sections = [];
    let box = page;
    const byName = this.ctx.browser.byName;
    for (const line of info.settings.split("\n")) {
      if (line.startsWith("# ")) {
        const title = line.slice(2);
        const det = el("details", "insp-section");
        det.open = sectionOpen.get(title) ?? false;
        det.append(el("summary", "", title));
        det.addEventListener("toggle", () => {
          if (!this.filtering) sectionOpen.set(title, det.open);
        });
        det.dataset.title = title;
        this.sections.push(det);
        page.append(det);
        box = det;
        continue;
      }
      const s = byName.get(line);
      if (!s) continue;
      box.append(this.row(s));
    }

    const more = el("details", "insp-section insp-more");
    more.append(el("summary", "", "How these values come about"));
    this.explain = el("div", "insp-explain");
    more.append(this.explain);
    page.append(more);
    root.append(page);
    this.update();
  }

  row(s) {
    const row = el("div", "row setting-row insp-row");
    const label = el("div", "label");
    const name = el("div", "name", s.label);
    name.title = s.doc;
    const tag = el("div", "tag");
    label.append(name, tag);
    const editor = this.ctx.browser.makeEditor(s, "inspector", (n, v) => {
      const [zmin, zmax] = this.scope();
      return this.ctx.setScoped(n, v, zmin, zmax);
    });
    const reset = el("button", "flat icon insp-reset", "↺");
    reset.title = "Remove the change";
    reset.onclick = () => {
      const [zmin, zmax] = this.scope();
      this.ctx.resetScoped(s.name, zmin, zmax, this.info.z);
    };
    row.append(label, editor.node, reset);
    const r = { info: s, row, editor, tag, reset, needle: `${s.label} ${s.name}`.toLowerCase() };
    this.rows.push(r);
    return row;
  }

  // New numbers and values in the same rows.
  update() {
    const info = this.info;
    if (!info || !this.title) return;
    this.title.textContent = `${info.title} · layer ${info.layer + 1}`;
    this.statValues[0].textContent = `${info.plannedSpeed.toFixed(0)} mm/s`;
    this.statValues[1].textContent = `${info.speed.toFixed(0)} mm/s`;
    this.statValues[1].classList.toggle("warning", info.slowReason !== 0);
    this.statValues[2].textContent = `${info.flow.toFixed(1)} mm³/s`;
    this.note.textContent = SLOW_NOTES[info.slowReason] ?? "";
    this.note.hidden = info.slowReason === 0;
    this.explain.textContent = info.explain;
    for (const r of this.rows) {
      const entry = info.values[r.info.name];
      r.editor.update(entry);
      const mine = entry && (entry.over || entry.level === 5 || entry.level === 6);
      r.tag.textContent = entry?.over ? "Changed for some layers" : sourceText(entry);
      r.tag.hidden = !r.tag.textContent;
      r.tag.classList.toggle("mine", !!mine);
      r.reset.style.visibility = mine ? "visible" : "hidden";
    }
    this.fillMark();
  }

  fillMark() {
    const box = this.markBox;
    box.replaceChildren();
    const m = this.info.mark;
    box.hidden = !m;
    if (!m) return;
    box.append(el("div", "heading", "Support you added"));
    const line = el("div", "insp-mark-line");
    const kind = el("select", "choice");
    MARK_KINDS.forEach((k, i) => kind.append(new Option(k, String(i))));
    kind.value = String(m.kind);
    const r = el("input", "num");
    r.type = "number";
    r.min = "0.5";
    r.max = "30";
    r.step = "0.5";
    r.value = String(m.r);
    r.title = "The radius of the area of the mark, mm";
    const send = () => this.ctx.markSet(m.index, Number(kind.value), Math.min(30, Math.max(0.5, Number(r.value) || m.r)));
    kind.onchange = send;
    r.onchange = send;
    const rm = el("button", "destructive", "Remove");
    rm.onclick = () => this.ctx.markRemove(m.index);
    line.append(kind, r, el("span", "dim", "mm"), rm);
    box.append(line);
  }

  filter(text) {
    const needle = text.trim().toLowerCase();
    this.filtering = needle !== "";
    for (const r of this.rows) r.row.hidden = needle !== "" && !r.needle.includes(needle);
    for (const d of this.sections) d.open = needle !== "" ? true : (sectionOpen.get(d.dataset.title) ?? false);
  }

  // The "why" of number i: its text, with a link for each {{setting}}.
  showWhy(anchor, i) {
    const info = this.info;
    const text = [info.whyPlanned, info.whyReal, info.whyFlow][i];
    if (!text) return;
    const box = el("div", "why");
    const byName = this.ctx.browser.byName;
    let at = 0;
    for (const m of text.matchAll(/\{\{([^}]*)\}\}/g)) {
      box.append(document.createTextNode(text.slice(at, m.index)));
      const name = m[1];
      const a = el("a", "", byName.get(name)?.label ?? name);
      a.href = "#";
      a.onclick = (e) => {
        e.preventDefault();
        closeMenu();
        this.focusSetting(name);
      };
      box.append(a);
      at = m.index + m[0].length;
    }
    box.append(document.createTextNode(text.slice(at)));
    openPopover(anchor, box);
  }

  // A link of a "why" text: the editor of that setting on this page, or
  // the setting in the Settings page.
  focusSetting(name) {
    const r = this.rows.find((x) => x.info.name === name);
    if (r) {
      const d = r.row.closest("details");
      if (d) d.open = true;
      const input = r.editor.node.querySelector("input, select, button");
      if (input) {
        input.focus();
        return;
      }
    }
    this.ctx.openSetting(name);
  }

  // The text of a value, for tests.
  valueText(name) {
    const r = this.rows.find((x) => x.info.name === name);
    return r ? displayValue(r.info, this.info.values[name]?.value ?? "") : null;
  }
}
