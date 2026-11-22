// search.js: the search of settings and actions (docs/internals/one-view.md).
//
// The search field is always in the header. Text in it (or `/`) shows
// the results under it. The undock button of the field makes the search a
// card over the view: the user can move it and change its size, and
// spatial.js keeps its place, its size, and the choice. The dock button of
// the card puts the search back in the header. The pin buttons put it on
// the left or the right rail of the view. Results under the field close
// at a click outside them; a card or a rail stays (it is pinned). The results are live controls: a number has
// a slider and an entry, a choice its list, a switch its switch. A change
// goes to the core at once (a drag sends a value at most each 90 ms), the
// core slices again, and the view behind the search shows the new slice.
// The pointer over a result shows the lines that the setting changes (the
// focus of the settings browser).
//
// Keys: the arrow keys go through the results; Left and Right change the
// value of the result (a step, or the next choice); Space or Enter turns a
// switch or runs an action; V turns the eye of the result on or off; Tab
// goes into the controls; Esc closes.
//
// The search does not block the view: a drag in the view turns it, the
// wheel zooms, and a click picks a line, while the results stay open.
// Esc, /, or × closes them.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { searchSettings } from "./format.js";
import { ALL_FEATURES, GROUP_TITLES, isNumber, isRatio, displayValue, toCore, formatNumber, sourceText } from "./format.js";
import { spatial, saved, remember } from "./spatial.js";

const MAX_SETTINGS = 14;

// Words with the same meaning in a search: the names of zslice, and the
// names of other slicers (Cura, PrusaSlicer). A word of the query also
// finds the other words of its groups, with a lower score.
const SAME = [
  ["speed", "speeds", "motion", "velocity", "fast", "slow", "mm/s", "feedrate", "accel", "acceleration", "jerk", "max speed"],
  ["acceleration", "accel", "jerk", "motion"],
  ["temperature", "temp", "heat", "hot", "nozzle temp", "bed temp", "temperatures"],
  ["fan", "cooling", "cool", "fans"],
  ["wall", "walls", "perimeter", "perimeters", "shell", "shells", "outline"],
  ["infill", "fill", "density", "sparse"],
  ["skin", "top", "bottom", "solid", "top and bottom"],
  ["support", "supports", "overhang", "overhangs", "tree"],
  ["brim", "skirt", "adhesion", "raft"],
  ["retraction", "retract", "stringing", "z hop", "wipe"],
  ["travel", "moves", "combing", "avoid"],
  ["layer", "layers", "height", "layer height", "resolution"],
  ["first layer", "initial", "first", "bed adhesion"],
  ["flow", "extrusion", "multiplier", "extrusion multiplier", "volumetric"],
  ["seam", "z seam", "scarf"],
  ["bridge", "bridges", "bridging"],
  ["ironing", "iron", "smooth"],
  ["shrink", "shrinkage", "compensation", "xy offset", "horizontal expansion", "elephant foot"],
  ["gcode", "g-code", "start", "end", "macro"],
  ["bed", "plate", "build plate", "bed size"],
  ["line width", "extrusion width", "width"],
];

// The words of the query word `w`: itself (score 1), and the words of its
// groups (score 0.75). A group counts when one of its words starts with w.
function alternatives(w) {
  const out = new Map([[w, 1]]);
  if (w.length < 3) return out;
  for (const g of SAME) {
    if (!g.some((x) => x.startsWith(w))) continue;
    for (const x of g) if (!out.has(x)) out.set(x, 0.75);
  }
  return out;
}

// The score of one word (or a phrase) in a setting: 0 for no match.
function wordScore(info, w) {
  const label = info.label.toLowerCase();
  if (label.startsWith(w)) return 40;
  if (label.split(/\s+/).some((x) => x.startsWith(w))) return 30;
  if (label.includes(w)) return 20;
  if (info.name.toLowerCase().includes(w.replace(/\s+/g, "_"))) return 14;
  if (info.section.toLowerCase().includes(w)) return 12;
  if (info.doc.toLowerCase().includes(w)) return 3;
  return 0;
}
const MAX_ACTIONS = 4;
const DRAG_MS = 90;
// The place of the box after a move (this browser only).
const PLACE_KEY = "zslice.search.place";

function loadPlace() {
  try {
    const p = JSON.parse(localStorage.getItem(PLACE_KEY) ?? "null");
    return p && Number.isFinite(p.x) && Number.isFinite(p.y) ? p : null;
  } catch {
    return null;
  }
}

function savePlace(p) {
  try {
    localStorage.setItem(PLACE_KEY, JSON.stringify(p));
  } catch {
    // No storage: the box opens at its first place next time.
  }
}

// The score of a setting for the words of a query: 0 for no match. Each
// word must match, by itself or by a word of its groups (SAME).
function score(info, words) {
  let total = 0;
  for (const w of words) {
    let best = 0;
    for (const [x, k] of alternatives(w)) best = Math.max(best, k * wordScore(info, x));
    if (best === 0) return 0;
    total += best;
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
    this.scope = null;
    // The field in the header (index.html). The entry and the scope go
    // into the head of the card while the search is undocked and open.
    const $ = (id) => document.getElementById(id);
    this.field = $("search-field");
    this.input = $("search-input");
    this.scopeTag = $("search-scope");
    this.fieldClose = $("search-close");
    this.openButton = $("search-open");
    // Where the search opens: "header" (the results under the field),
    // "card" (a card over the view that the user moves), or "left" or
    // "right" (pinned to that rail of the view, the height of the view).
    // The card and the rails are pinned: they stay open until × or Esc.
    // The results under the field close at a click outside them.
    const was = saved("search");
    this.place = ["card", "left", "right"].includes(was.place) ? was.place : was.undocked === true ? "card" : "header";
    this.input.addEventListener("input", () => {
      if (this.root) this.fill();
      else this.show(null, null, false);
    });
    // A click in the docked field shows the results.
    this.input.addEventListener("focus", () => {
      if (!this.root && !this.undocked) this.show(null, null, false);
    });
    this.input.addEventListener("keydown", (e) => {
      if (this.root) this.key(e);
    });
    this.fieldClose.onclick = () => this.close();
    $("search-undock").onclick = () => this.setPlace("card");
    this.openButton.onclick = () => this.show();
    this.placeField();
    this.onResize = () => {
      this.placeDocked();
      this.placeRail();
    };
  }

  get open() {
    return !!this.root;
  }

  // The search is not in the header: the header shows a Search button.
  get undocked() {
    return this.place !== "header";
  }

  // The search stays open at a click outside it.
  get pinned() {
    return this.place !== "header";
  }

  // The header shows the field (docked), or a Search button that opens
  // the card (undocked).
  placeField() {
    this.field.hidden = this.undocked;
    this.openButton.hidden = !this.undocked;
  }

  // Docks the search in the header, or undocks it into a card. The search
  // opens again in its new place, with its text.
  setDocked(docked) {
    this.setPlace(docked ? "header" : "card");
  }

  // Moves the search to a place ("header", "card", "left", or "right"),
  // and opens it there again with its text.
  setPlace(place) {
    const scope = this.scope;
    this.close();
    this.place = place;
    remember("search", { place, undocked: place !== "header" });
    this.placeField();
    this.show(null, scope);
  }

  // A small icon button of the search (pin, dock, close).
  button(cls, svg, title, action) {
    const b = el("button", `flat icon ${cls}`);
    b.innerHTML = svg;
    b.title = title;
    b.setAttribute("aria-label", title.split(":")[0]);
    b.onclick = action;
    return b;
  }

  // The buttons that move the search to the other places.
  placeButtons() {
    const svg = (d) => `<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
    const out = [];
    if (this.place !== "left") out.push(this.button("search-pin", svg("M2.5 2.5v11M5.5 4.5h8v7h-8z"), "Pin to the left rail: the search stays open at the left of the view", () => this.setPlace("left")));
    if (this.place !== "right") out.push(this.button("search-pin", svg("M13.5 2.5v11M2.5 4.5h8v7h-8z"), "Pin to the right rail: the search stays open at the right of the view", () => this.setPlace("right")));
    if (this.place !== "card") out.push(this.button("search-pin", svg("M9.5 2.5h4v4M13.5 2.5 8 8M7 3.5H2.5v10h10V9"), "Undock the search: a card over the view that you can move and resize", () => this.setPlace("card")));
    if (this.place !== "header") out.push(this.button("search-dock", svg("M2.5 2.5h11M8 13.5V6M5 9l3-3 3 3"), "Dock the search: put it back in the header", () => this.setPlace("header")));
    return out;
  }

  // The left and right rails: the height of the view, beside the tool
  // strip (left) or at the right edge of the view.
  placeRail() {
    if (!this.root || (this.place !== "left" && this.place !== "right")) return;
    const view = document.getElementById("gl").getBoundingClientRect();
    const strip = document.querySelector(".toolstrip")?.getBoundingClientRect();
    const dock = document.getElementById("dock")?.getBoundingClientRect();
    const w = Math.min(380, Math.max(260, view.width * 0.3));
    const top = view.top + 8;
    const bottom = dock && dock.height > 0 ? Math.min(view.bottom, dock.top) - 8 : view.bottom - 8;
    const x = this.place === "left" ? Math.max(view.left + 8, strip && strip.width > 0 ? strip.right + 8 : 0) : view.right - w - 8;
    this.box.style.left = `${x}px`;
    this.box.style.top = `${top}px`;
    this.box.style.width = `${w}px`;
    this.box.style.height = `${Math.max(160, bottom - top)}px`;
  }

  // scope: null for the settings of the print, or the settings of one
  // part: { label, set(name, value) -> Promise<error>, value(name) ->
  // Promise<text or null> }. A part shows only the settings that a part
  // can have of its own. A scope with only(info) shows only the settings
  // that pass it (the layers of rangecard.js). text: the new text of the
  // entry, or null to keep its text. focus: false when the user types in
  // the field.
  show(text = null, scope = null, focus = true) {
    if (this.root && scope !== this.scope) this.close();
    this.scope = scope;
    if (text !== null) this.input.value = text;
    if (this.root) {
      if (text !== null) this.fill();
      this.input.focus();
      this.input.select();
      return;
    }
    this.scopeTag.hidden = !scope;
    this.scopeTag.textContent = scope ? scope.label : "";
    this.input.placeholder = scope ? "Search the settings of this part" : "Search settings and actions";
    // No shade over the view: the view takes the mouse while the search
    // is open, so the user can turn the view to see a change.
    const box = el("div", "search-box");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Search settings and actions");
    const list = el("div", "search-list");
    this.root = el("div", "search-layer");
    this.root.append(box);
    this.box = box;
    if (this.undocked) {
      const head = el("label", "search-head");
      const closeBtn = el("button", "flat icon search-close", "×");
      closeBtn.title = "Close the search (Esc)";
      closeBtn.setAttribute("aria-label", "Close the search");
      closeBtn.onclick = () => this.close();
      if (this.place === "card") {
        const grip = el("span", "search-grip");
        grip.title = "Drag to move the search. Double-click: back to its first place.";
        grip.setAttribute("aria-hidden", "true");
        head.append(grip, this.scopeTag, this.input, ...this.placeButtons(), closeBtn);
        this.movable(box, head);
        // Its size stays for the next search (spatial.js).
        spatial(box, "search");
      } else {
        // A rail: no drag; the window size places it.
        box.classList.add("rail", this.place);
        head.classList.add("rail-head");
        head.append(this.scopeTag, this.input, ...this.placeButtons(), closeBtn);
        window.addEventListener("resize", this.onResize);
      }
      box.append(head, list);
    } else {
      // Under the field of the header, with no head: the field is its
      // head.
      box.classList.add("docked");
      // The scope of a part goes over the results: the field stays wide
      // enough for the text.
      // The scope of a part, and the buttons that pin the search to a
      // rail, go over the results.
      const row = el("div", "search-scope-row");
      if (scope) row.append(this.scopeTag);
      const pins = el("span", "search-pins");
      pins.append(...this.placeButtons().filter((b) => !b.classList.contains("search-dock")));
      row.append(pins);
      box.append(row);
      box.append(list);
      this.field.classList.add("open");
      this.fieldClose.hidden = false;
      window.addEventListener("resize", this.onResize);
    }
    // The keys of the entry come from its own listener.
    box.addEventListener("keydown", (e) => {
      if (e.target !== this.input) this.key(e);
    });
    document.body.append(this.root);
    this.list = list;
    this.placeDocked();
    this.placeRail();
    // Not pinned: a click outside the results and the field closes them.
    // A drag in the view (a turn, a pan) keeps them open.
    if (!this.pinned) {
      let down = null;
      this.outsideDown = (e) => {
        down = this.root?.contains(e.target) || this.field.contains(e.target) ? null : { x: e.clientX, y: e.clientY };
      };
      this.outsideUp = (e) => {
        if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) < 5) this.close();
        down = null;
      };
      document.addEventListener("pointerdown", this.outsideDown, true);
      document.addEventListener("pointerup", this.outsideUp, true);
    }
    this.fill();
    if (focus) {
      this.input.focus();
      this.input.select();
    }
  }

  // The results of the docked search: under the field, at least 640
  // pixels wide, inside the window.
  placeDocked() {
    if (!this.root || this.undocked) return;
    const r = this.field.getBoundingClientRect();
    const w = Math.min(Math.max(r.width, 640), window.innerWidth - 16);
    const x = Math.max(8, Math.min(window.innerWidth - w - 8, r.left + r.width / 2 - w / 2));
    this.box.style.width = `${w}px`;
    this.box.style.left = `${x}px`;
    this.box.style.top = `${r.bottom + 6}px`;
  }

  // The box moves with a drag of its head (not of the entry). It stays in
  // the window, and opens at the same place next time.
  movable(box, head) {
    const place = (x, y) => {
      const w = box.offsetWidth;
      const h = box.offsetHeight;
      const cx = Math.max(8, Math.min(window.innerWidth - w - 8, x));
      const cy = Math.max(8, Math.min(window.innerHeight - Math.min(h, 80) - 8, y));
      box.style.left = `${cx}px`;
      box.style.top = `${cy}px`;
      box.style.transform = "none";
      return { x: cx, y: cy };
    };
    // The first place: centered under the Search button of the header,
    // at the top of the view.
    const first = () => {
      const b = document.getElementById("search-open")?.getBoundingClientRect();
      if (!b || b.width === 0) return;
      place(b.left + b.width / 2 - box.offsetWidth / 2, b.bottom + 6);
    };
    const saved = loadPlace();
    requestAnimationFrame(() => (saved ? place(saved.x, saved.y) : first()));
    head.addEventListener("pointerdown", (e) => {
      // The entry and the × keep their own clicks: a capture here sends
      // the click to the head.
      if (e.button !== 0 || e.target.closest("input, button")) return;
      e.preventDefault();
      const r = box.getBoundingClientRect();
      const dx = e.clientX - r.left;
      const dy = e.clientY - r.top;
      head.setPointerCapture(e.pointerId);
      head.classList.add("moving");
      let last = null;
      const move = (ev) => {
        last = place(ev.clientX - dx, ev.clientY - dy);
      };
      const up = () => {
        head.removeEventListener("pointermove", move);
        head.removeEventListener("pointerup", up);
        head.removeEventListener("pointercancel", up);
        head.classList.remove("moving");
        if (last) savePlace(last);
        this.input.focus();
      };
      head.addEventListener("pointermove", move);
      head.addEventListener("pointerup", up);
      head.addEventListener("pointercancel", up);
    });
    head.addEventListener("dblclick", (e) => {
      if (e.target.closest("input")) return;
      first();
      try {
        localStorage.removeItem(PLACE_KEY);
      } catch {
        // No storage.
      }
    });
  }

  // The setting whose lines the view shows alone (its eye is on), or null.
  setEye(name) {
    this.eyeOn = name;
    for (const r of this.rows) {
      if (!r.eye) continue;
      r.eye.classList.toggle("on", r.name === name);
      r.eye.setAttribute("aria-pressed", String(r.name === name));
    }
    if (!name) {
      this.ctx.unfocus();
      return;
    }
    const fx = this.ctx.browser.ctx.effect(name);
    this.ctx.focus(fx.features || ALL_FEATURES, fx.firstLayerOnly);
  }

  close() {
    if (!this.root) return;
    this.eyeOn = null;
    // The editors of the search leave the live list of the browser.
    for (const [name, list] of this.ctx.browser.editors) this.ctx.browser.editors.set(name, list.filter((e) => e.where !== "search"));
    // The entry and the scope go back to the field of the header.
    const had = document.activeElement === this.input;
    this.scopeTag.hidden = true;
    this.input.placeholder = "Search settings and actions";
    // They go before the key sign (/), in the order of index.html.
    this.field.querySelector(".search-kbd").before(this.scopeTag);
    this.scopeTag.after(this.input);
    this.field.classList.remove("open");
    this.fieldClose.hidden = true;
    window.removeEventListener("resize", this.onResize);
    if (this.outsideDown) {
      document.removeEventListener("pointerdown", this.outsideDown, true);
      document.removeEventListener("pointerup", this.outsideUp, true);
      this.outsideDown = this.outsideUp = null;
    }
    if (had) this.input.blur();
    this.scope = null;
    this.root.remove();
    this.root = null;
    this.box = null;
    this.rows = [];
    this.ctx.unfocus();
    // A removed element sends no focusout: the edit of the history ends
    // here.
    this.ctx.closed?.();
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
    // The ranking of the core (zs_setting_search), the same in each app;
    // the rules here only with no core.
    const byIndex = new Map(this.ctx.infos.map((info) => [info.index, info]));
    // A scope with `only` (the layers of rangecard.js) keeps the settings
    // that pass it; any other scope is a part.
    const only = this.scope?.only;
    const core = searchSettings(q, !!this.scope && !only, only ? 2000 : 200);
    const matches = (core
      ? core.map((h) => ({ info: byIndex.get(h.index), s: h.score })).filter((r) => r.info)
      : this.ctx.infos
          .filter((info) => !this.scope || only || info.perPart)
          .map((info) => ({ info, s: score(info, words) }))
          .filter((r) => r.s > 0)
          .sort((a, b) => b.s - a.s)).filter((r) => !only || only(r.info));
    const settings = matches.slice(0, MAX_SETTINGS);
    const actions = (this.scope ? [] : this.ctx.actions())
      .map((a) => ({ a, s: words.every((w) => a.label.toLowerCase().includes(w) || (a.hint ?? "").toLowerCase().includes(w)) ? 1 : 0 }))
      .filter((r) => r.s > 0)
      .slice(0, MAX_ACTIONS);
    if (settings.length > 0) {
      this.list.append(el("div", "search-group", "Settings"));
      for (const { info } of settings) this.list.append(this.settingRow(info));
      if (matches.length > settings.length) {
        this.list.append(el("div", "search-note", `${matches.length - settings.length} more settings match. Type more words to narrow the list.`));
      }
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
  }

  key(e) {
    const r = this.rows[this.index];
    const inControl = e.target.closest?.("input:not(.search-input), select, textarea");
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      if (inControl) this.select(this.index);
      else this.close();
    } else if (e.key === "Enter" && inControl && !e.target.closest("textarea")) {
      // The editor sends the value on Enter (its own key handler runs
      // first); then the focus goes back to the row, for the next
      // Up or Down.
      e.preventDefault();
      setTimeout(() => this.select(this.index), 0);
    } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && !inControl) {
      e.preventDefault();
      this.select(this.index + (e.key === "ArrowDown" ? 1 : -1));
    } else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && !inControl && e.target !== this.input && r?.nudge) {
      e.preventDefault();
      r.nudge(e.key === "ArrowRight" ? 1 : -1);
    } else if ((e.key === "v" || e.key === "V") && !inControl && e.target !== this.input && r?.eye) {
      e.preventDefault();
      this.setEye(this.eyeOn === r.name ? null : r.name);
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
    // The history: the edits of this row are one step while the focus
    // stays in it (app.js, sendFocus).
    row.dataset.setting = info.name;
    const label = el("div", "search-label");
    const tag = el("div", "search-tag");
    label.append(el("div", "", info.label), tag);
    label.title = info.doc;
    const scope = this.scope;
    // A part: the edits go to the part, and the editor shows its value
    // (or the value of the plate, until the part has its own).
    let refresh = null;
    const set = scope
      ? async (name, value) => {
        const error = await scope.set(name, value);
        refresh?.();
        return error;
      }
      : browser.ctx.set;
    const editor = browser.makeEditor(info, info.multiline ? "row" : "search", set);
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
        set(info.name, toCore(info, text));
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
    const show = (entry) => {
      editor.update(entry);
      if (slider && entry && !dragging) slider.value = displayValue(info, entry.value);
      const t = sourceText(entry);
      tag.textContent = `${GROUP_TITLES[info.group]} · ${info.section}${t ? ` · ${t}` : ""}`;
    };
    if (scope) {
      refresh = async () => {
        const own = await scope.value(info.name);
        const plate = browser.values[info.name];
        show(own !== null && own !== undefined ? { ...plate, value: own, level: 6, formula: null } : plate);
      };
      refresh();
    } else {
      browser.track(info.name, { where: "search", update: show });
    }
    // The eye: the view shows only the lines that this setting changes
    // (the others as ghosts), until a click on it again. The view does
    // not change by itself while the user goes through the results.
    const eye = el("button", "flat icon search-eye");
    eye.innerHTML = '<svg viewBox="0 0 18 18" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M1.5 9s2.8-5 7.5-5 7.5 5 7.5 5-2.8 5-7.5 5-7.5-5-7.5-5z"/><circle cx="9" cy="9" r="2.3"/></svg>';
    eye.title = "Show only the lines that this setting changes (the others as ghosts). Key: V";
    // Tab goes to the value, not to the eye: the eye has its key (V).
    eye.tabIndex = -1;
    eye.setAttribute("aria-label", `${info.label}: show only its lines`);
    eye.setAttribute("aria-pressed", String(this.eyeOn === info.name));
    eye.classList.toggle("on", this.eyeOn === info.name);
    eye.onclick = (e) => {
      e.stopPropagation();
      this.setEye(this.eyeOn === info.name ? null : info.name);
    };
    label.after(eye);
    row.onmouseenter = () => {
      this.select(this.rows.indexOf(entryRow), false);
    };
    // Left and Right: one step of a number, or the next choice.
    const nudge = (dir) => {
      const shownValue = editor.node.querySelector("input.num, input.text")?.value;
      const value = (scope && shownValue !== undefined ? toCore(info, shownValue) : null) ?? browser.values[info.name]?.value ?? info.defaultValue;
      if (isNumber(info)) {
        const step = info.sliderStep > 0 ? info.sliderStep : info.kind === "integer" ? 1 : isRatio(info) ? 0.01 : 0.1;
        const v = Number(value) + dir * step;
        set(info.name, String(Number(v.toPrecision(10))));
      } else if (info.kind === "choice") {
        const sel = editor.node.querySelector("select");
        const cur = sel ? sel.value : value;
        const i = info.choices.indexOf(cur);
        const n = info.choices.length;
        set(info.name, info.choices[(i + dir + n) % n]);
      } else if (info.kind === "boolean") {
        const on = editor.node.querySelector(".switch")?.classList.contains("on") ?? value === "true";
        set(info.name, on ? "false" : "true");
      }
    };
    // Enter: into the value, with its text selected, so that a number
    // typed replaces it, and Up and Down step it. Enter or Esc there goes
    // back to the row (see key).
    const activate = () => {
      if (info.kind === "boolean") return nudge(1);
      const c = editor.node.querySelector("input.num, input.text, select, textarea");
      c?.focus();
      c?.select?.();
    };
    const entryRow = { node: row, nudge, activate, name: info.name, eye };
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
    const entryRow = { node: row, activate };
    row.onmouseenter = () => this.select(this.rows.indexOf(entryRow), false);
    this.rows.push(entryRow);
    return row;
  }
}
