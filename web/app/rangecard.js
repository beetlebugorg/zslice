// rangecard.js: the card of a range of layers. A left drag of the Select
// tool that starts on a printed line lights the layers from the layer of
// that line to the layer under the pointer (zs_view_light_layers). On the
// release this card opens beside the lit layers, never over them. It
// shows "Layers A–B" and the settings that can change for some layers
// (settings.zig, layer_settings): a few that matter most, and "+ Add a
// setting for these layers" for the others. An edit is an override of
// the range (setScoped with zmin and zmax), and slices at once. The first
// row is the filament of the layers: a chip for each filament of the
// plate (filaments.js). A filament of its own makes a filament change at
// the first layer and back after the last.
//
// One call to the worker opens the card (setScoped with no change
// returns the values too), and one call makes each edit. The card does no
// work for each frame: app.js calls `place` after a frame, which projects
// 8 points.
//
// Esc, a click elsewhere in the view, or × closes the card and ends the
// light.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";
import { spatial, savedPlace, remember } from "./spatial.js";
import { placeBeside, freeArea } from "./place.js";

// The settings that the card shows first, in order, when the setting can
// change for some layers.
export const RANGE_SETTINGS = [
  "project.filament",
  "project.infill_density",
  "project.infill_pattern",
  "project.wall_count",
  "project.top_thickness",
  "project.outer_wall_speed",
  "project.infill_speed",
  "filament.fan_speed",
  "filament.nozzle_temp",
];

export class RangeCard {
  // ctx: { browser (SettingsBrowser), host (the element of the view),
  //        pixelOf([x, y, z]) -> device pixels or null, bounds() -> the
  //        print box [x0, y0, x1, y1] mm or null, layerZ(l) (the top of
  //        layer l, mm), layerBottom(l), edit(name, value, zmin, zmax,
  //        names) -> Promise<{ error, at }>, reset(name, zmin, zmax,
  //        names) -> Promise<{ at }>, values(zmin, names) -> Promise<at>,
  //        search(text, scope), close() }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.range = null; // [lo, hi], the layers
    this.rows = [];
    this.userAt = null;
  }

  get open() {
    return !!this.node;
  }

  // The z range of the edits: the tops of the first and the last layer
  // (an override covers the layers with a top in it).
  zRange() {
    const [lo, hi] = this.range;
    return [this.ctx.layerZ(lo), this.ctx.layerZ(hi)];
  }

  // The names of the rows: the settings of RANGE_SETTINGS that can change
  // for some layers, and the ones that the user added.
  names() {
    return this.rows.map((r) => r.info.name);
  }

  async show(lo, hi) {
    this.range = [Math.min(lo, hi), Math.max(lo, hi)];
    if (!this.node) this.build();
    const [a, b] = this.range;
    this.title.textContent = a === b ? `Layer ${a + 1}` : `Layers ${a + 1}–${b + 1}`;
    const [z0, z1] = this.zRange();
    this.facts.textContent = `z ${(this.ctx.layerBottom(a)).toFixed(2)} to ${z1.toFixed(2)} mm · ${b - a + 1} ${b === a ? "layer" : "layers"}`;
    this.fill(await this.ctx.values(z0, this.names()));
    this.place();
  }

  close() {
    if (!this.node) return;
    this.node.remove();
    this.node = null;
    this.range = null;
    this.userAt = null;
    this.ctx.close?.();
  }

  build() {
    const card = el("div", "part-card range-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The selected layers");
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title");
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close (Esc)";
    close.onclick = () => this.close();
    head.append(this.title, close);
    head.title = "Drag to move the card";
    movable(card, head, this.ctx.host, (x, y) => {
      this.userAt = [x, y];
      remember("range-card", { x, y });
    });
    // Its place and size stay for the next card (spatial.js).
    spatial(card, "range-card", head, () => {
      this.userAt = null;
      this.place();
    });
    this.facts = el("div", "lc-size");
    this.box = el("div", "lc-settings");
    const add = el("button", "flat pc-add", "+ Add a setting for these layers");
    add.title = "Search the settings that can change for some layers";
    add.onclick = () => this.ctx.search("", this.scope());
    card.append(head, this.facts, el("div", "dim caption", "Changes here are for these layers of this print."), this.box, add);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.close();
      }
    });
    const byName = this.ctx.browser.byName;
    this.rows = [];
    for (const name of RANGE_SETTINGS) {
      const info = byName.get(name);
      if (info?.perLayer) this.addRow(info);
    }
    this.ctx.host.append(card);
    this.node = card;
  }

  addRow(info) {
    if (this.rows.some((r) => r.info.name === info.name)) return;
    const row = el("div", "lc-row");
    const label = el("div", "lc-label");
    label.append(el("div", "lc-name", info.label));
    label.title = info.doc;
    const editor = this.ctx.browser.makeEditor(info, "range", (n, v) => this.set(n, v));
    const reset = el("button", "flat icon pc-clear", "↺");
    reset.title = "Remove the change for these layers";
    reset.setAttribute("aria-label", `${info.label}: remove the change for these layers`);
    reset.onclick = () => this.reset(info.name);
    row.append(label, editor.node, reset);
    this.box.append(row);
    this.rows.push({ info, editor, reset });
  }

  // The values at the first layer: { name: entry } (core.valueAt).
  fill(at) {
    if (!this.node || !at) return;
    for (const r of this.rows) {
      const entry = at[r.info.name];
      if (!entry) continue;
      r.editor.update(entry);
      r.reset.style.visibility = entry.over ? "visible" : "hidden";
    }
  }

  async set(name, value) {
    if (!this.range) return "No layers.";
    const [z0, z1] = this.zRange();
    const r = await this.ctx.edit(name, value, z0, z1, this.names());
    this.fill(r.at);
    return r.error;
  }

  async reset(name) {
    if (!this.range) return;
    const [z0, z1] = this.zRange();
    const r = await this.ctx.reset(name, z0, z1, this.names());
    this.fill(r.at);
  }

  // The search scope of these layers: only the settings that can change
  // for some layers. A setting that the user sets there gets a row.
  scope() {
    const [a, b] = this.range;
    return {
      label: a === b ? `Layer ${a + 1}` : `Layers ${a + 1}–${b + 1}`,
      only: (info) => info.perLayer,
      set: async (name, value) => {
        const info = this.ctx.browser.byName.get(name);
        if (info && this.node) this.addRow(info);
        return this.set(name, value);
      },
      value: async (name) => {
        if (!this.range) return null;
        const at = await this.ctx.values(this.zRange()[0], [name]);
        return at?.[name]?.value ?? null;
      },
    };
  }

  // Beside the lit layers: the box of the print from the bottom of the
  // first layer to the top of the last, on the screen. The card covers
  // no part of it.
  place() {
    const card = this.node;
    if (!card || !this.range) return;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
    const b = this.ctx.bounds();
    if (!b) return;
    const dpr = window.devicePixelRatio || 1;
    const za = this.ctx.layerBottom(this.range[0]);
    const zb = this.ctx.layerZ(this.range[1]);
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    for (const x of [b[0], b[2]]) for (const y of [b[1], b[3]]) for (const z of [za, zb]) {
      const q = this.ctx.pixelOf([x, y, z]);
      if (!q) continue;
      box[0] = Math.min(box[0], q[0] / dpr);
      box[1] = Math.min(box[1], q[1] / dpr);
      box[2] = Math.max(box[2], q[0] / dpr);
      box[3] = Math.max(box[3], q[1] / dpr);
    }
    // The place where the user put the card before, if it is clear of
    // what the card is about.
    const kept = savedPlace("range-card", card, this.ctx.host, box[0] <= box[2] ? box : null);
    if (kept) {
      card.style.left = `${kept[0]}px`;
      card.style.top = `${kept[1]}px`;
      return;
    }
    const area = freeArea(this.ctx.host);
    const [x, y] = box[0] <= box[2] ? placeBeside(box, area, card.offsetWidth, card.offsetHeight) : [area[2] - card.offsetWidth, area[1] + 52];
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }
}
