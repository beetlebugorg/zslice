// search.js: the search of settings and actions (docs/internals/one-view.md).
//
// `/` opens it over the view. The results are live controls: a number has
// a slider and an entry, a choice its list, a switch its switch. A change
// goes to the core at once (a drag sends a value at most each 90 ms), the
// core slices again, and the view behind the search shows the new slice.
// The pointer over a result shows the lines that the setting changes (the
// focus of the settings browser).
//
// Keys: the arrow keys go through the results; Left and Right change the
// value of the result (a step, or the next choice); Space or Enter turns a
// switch or runs an action; Tab goes into the controls; Esc closes.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { ALL_FEATURES, GROUP_TITLES, isNumber, isRatio, displayValue, toCore, formatNumber, sourceText } from "./format.js";

const MAX_SETTINGS = 8;
const MAX_ACTIONS = 4;
const DRAG_MS = 90;

// The score of a text for the words of a query: 0 for no match.
function score(info, words) {
  const label = info.label.toLowerCase();
  const name = info.name.toLowerCase();
  const section = info.section.toLowerCase();
  const doc = info.doc.toLowerCase();
  let total = 0;
  for (const w of words) {
    let s = 0;
    if (label.startsWith(w)) s = 40;
    else if (label.split(/\s+/).some((x) => x.startsWith(w))) s = 30;
    else if (label.includes(w)) s = 20;
    else if (name.includes(w)) s = 14;
    else if (section.includes(w)) s = 10;
    else if (doc.includes(w)) s = 3;
    if (s === 0) return 0;
    total += s;
  }
  // The settings of the part first, then the filament, then the printer.
  if (info.group === "project") total += 2;
  if (info.group === "engine") total -= 2;
  return total;
}

export class SearchOverlay {
  // ctx: { browser (SettingsBrowser), infos, actions() -> [{ label, keys,
  //        hint, run() }], focus(mask, firstLayerOnly), unfocus() }
  constructor(ctx) {
    this.ctx = ctx;
    this.root = null;
    this.rows = [];
    this.index = 0;
  }

  get open() {
    return !!this.root;
  }

  show(text = "") {
    if (this.root) {
      this.input.focus();
      this.input.select();
      return;
    }
    const shade = el("div", "search-shade");
    shade.onclick = () => this.close();
    const box = el("div", "search-box");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Search settings and actions");
    const head = el("label", "search-head");
    const input = document.createElement("input");
    input.className = "search-input";
    input.placeholder = "Search settings and actions";
    input.spellcheck = false;
    input.value = text;
    input.setAttribute("aria-label", "Search settings and actions");
    head.append(input, el("span", "search-esc", "Esc"));
    const list = el("div", "search-list");
    box.append(head, list);
    box.addEventListener("keydown", (e) => this.key(e));
    input.addEventListener("input", () => this.fill());
    this.root = el("div", "search-layer");
    this.root.append(shade, box);
    document.body.append(this.root);
    this.input = input;
    this.list = list;
    this.fill();
    input.focus();
  }

  close() {
    if (!this.root) return;
    // The editors of the search leave the live list of the browser.
    for (const [name, list] of this.ctx.browser.editors) this.ctx.browser.editors.set(name, list.filter((e) => e.where !== "search"));
    this.root.remove();
    this.root = null;
    this.rows = [];
    this.ctx.unfocus();
  }

  fill() {
    const browser = this.ctx.browser;
    for (const [name, list] of browser.editors) browser.editors.set(name, list.filter((e) => e.where !== "search"));
    const q = this.input.value.trim().toLowerCase();
    const words = q.split(/\s+/).filter(Boolean);
    this.list.replaceChildren();
    this.rows = [];
    if (words.length === 0) {
      this.list.append(el("div", "search-note", "Type a setting (infill, walls, brim, speed) or an action (export, arrange, print)."));
      return;
    }
    const settings = this.ctx.infos
      .map((info) => ({ info, s: score(info, words) }))
      .filter((r) => r.s > 0)
      .sort((a, b) => b.s - a.s)
      .slice(0, MAX_SETTINGS);
    const actions = this.ctx.actions()
      .map((a) => ({ a, s: words.every((w) => a.label.toLowerCase().includes(w) || (a.hint ?? "").toLowerCase().includes(w)) ? 1 : 0 }))
      .filter((r) => r.s > 0)
      .slice(0, MAX_ACTIONS);
    if (settings.length > 0) {
      this.list.append(el("div", "search-group", "Settings"));
      for (const { info } of settings) this.list.append(this.settingRow(info));
    }
    if (actions.length > 0) {
      this.list.append(el("div", "search-group", "Actions"));
      for (const { a } of actions) this.list.append(this.actionRow(a));
    }
    if (this.rows.length === 0) this.list.append(el("div", "search-note", "No setting or action matches."));
    this.select(0, false);
  }

  select(i, focusRow = true) {
    if (this.rows.length === 0) return;
    this.index = Math.max(0, Math.min(this.rows.length - 1, i));
    this.rows.forEach((r, k) => r.node.classList.toggle("on", k === this.index));
    const r = this.rows[this.index];
    r.node.scrollIntoView({ block: "nearest" });
    if (focusRow) r.node.focus();
    r.hover?.();
  }

  key(e) {
    const r = this.rows[this.index];
    const inControl = e.target.closest?.("input:not(.search-input), select, textarea");
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      if (inControl) this.select(this.index);
      else this.close();
    } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && !inControl) {
      e.preventDefault();
      this.select(this.index + (e.key === "ArrowDown" ? 1 : -1));
    } else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && !inControl && e.target !== this.input && r?.nudge) {
      e.preventDefault();
      r.nudge(e.key === "ArrowRight" ? 1 : -1);
    } else if ((e.key === "Enter" || e.key === " ") && !inControl && e.target !== this.input && r?.activate) {
      e.preventDefault();
      r.activate();
    } else if (e.key === "Enter" && e.target === this.input && r?.activate) {
      e.preventDefault();
      r.activate();
    } else if (e.key === "ArrowDown" && e.target === this.input) {
      e.preventDefault();
      this.select(this.index);
    }
  }

  // A setting with its live control.
  settingRow(info) {
    const browser = this.ctx.browser;
    const row = el("div", "search-row");
    row.tabIndex = -1;
    const label = el("div", "search-label");
    const tag = el("div", "search-tag");
    label.append(el("div", "", info.label), tag);
    label.title = info.doc;
    const editor = browser.makeEditor(info, info.multiline ? "row" : "search");
    const controls = el("div", "search-controls");
    let slider = null;
    let dragging = false;
    let last = 0;
    let pending = null;
    const k = isRatio(info) ? 100 : 1;
    if (isNumber(info) && info.sliderMax > info.sliderMin) {
      slider = document.createElement("input");
      slider.type = "range";
      slider.className = "search-slider";
      slider.min = String(info.sliderMin * k);
      slider.max = String(info.sliderMax * k);
      slider.step = String((info.sliderStep > 0 ? info.sliderStep : info.kind === "integer" ? 1 : (info.sliderMax - info.sliderMin) / 100) * k);
      slider.setAttribute("aria-label", info.label);
      // A drag sends a value at most each DRAG_MS, and the last one at
      // the end: each value starts a slice, and the core stops the slice
      // before it.
      const send = (text) => {
        pending = null;
        last = performance.now();
        browser.ctx.set(info.name, toCore(info, text));
      };
      slider.addEventListener("input", () => {
        dragging = true;
        const text = formatNumber(Number(slider.value));
        const entry = editor.node.querySelector("input");
        if (entry) entry.value = text;
        const wait = DRAG_MS - (performance.now() - last);
        clearTimeout(pending);
        pending = wait <= 0 ? (send(text), null) : setTimeout(() => send(text), wait);
      });
      slider.addEventListener("change", () => {
        dragging = false;
        clearTimeout(pending);
        send(formatNumber(Number(slider.value)));
      });
      controls.append(slider);
    }
    controls.append(editor.node);
    row.append(label, controls);
    browser.track(info.name, {
      where: "search",
      update: (entry) => {
        editor.update(entry);
        if (slider && entry && !dragging) slider.value = displayValue(info, entry.value);
        const t = sourceText(entry);
        tag.textContent = `${GROUP_TITLES[info.group]} · ${info.section}${t ? ` · ${t}` : ""}`;
      },
    });
    const hover = () => {
      const fx = browser.ctx.effect(info.name);
      this.ctx.focus(fx.features || ALL_FEATURES, fx.firstLayerOnly);
    };
    row.onmouseenter = () => {
      this.select(this.rows.indexOf(entryRow), false);
    };
    // Left and Right: one step of a number, or the next choice.
    const nudge = (dir) => {
      const value = browser.values[info.name]?.value ?? info.defaultValue;
      if (isNumber(info)) {
        const step = info.sliderStep > 0 ? info.sliderStep : info.kind === "integer" ? 1 : isRatio(info) ? 0.01 : 0.1;
        const v = Number(value) + dir * step;
        browser.ctx.set(info.name, String(Number(v.toPrecision(10))));
      } else if (info.kind === "choice") {
        const i = info.choices.indexOf(value);
        const n = info.choices.length;
        browser.ctx.set(info.name, info.choices[(i + dir + n) % n]);
      } else if (info.kind === "boolean") {
        browser.ctx.set(info.name, value === "true" ? "false" : "true");
      }
    };
    const activate = () => {
      if (info.kind === "boolean") nudge(1);
      else editor.node.querySelector("input, select, textarea")?.focus();
    };
    const entryRow = { node: row, hover, nudge, activate };
    this.rows.push(entryRow);
    return row;
  }

  actionRow(a) {
    const row = el("div", "search-row search-action");
    row.tabIndex = -1;
    const label = el("div", "search-label");
    label.append(el("div", "", a.label));
    if (a.hint) label.append(el("div", "search-tag", a.hint));
    row.append(label);
    if (a.keys) row.append(el("span", "search-keys", a.keys));
    const activate = () => {
      this.close();
      a.run();
    };
    row.onclick = activate;
    const entryRow = { node: row, activate, hover: () => this.ctx.unfocus() };
    row.onmouseenter = () => this.select(this.rows.indexOf(entryRow), false);
    this.rows.push(entryRow);
    return row;
  }
}
