// rangecard.js: the card of a range of layers. A left drag of the Select
// tool that starts on a printed line lights the layers from the layer of
// that line to the layer under the pointer (zs_view_light_layers). On the
// release this page shows in the Inspector (dock.js). It
// shows "Layers A–B" and the settings that can change for some layers
// (settings.zig, layer_settings): a few that matter most, and "+ Add a
// setting for these layers" for the others. An edit is an override of
// the range (setScoped with zmin and zmax), and slices at once. The first
// row is the filament of the layers: a chip for each filament of the
// plate (filaments.js). A filament of its own makes a filament change at
// the first layer and back after the last.
//
// A range that lights one body of the part (a drag that starts on a
// line, or Shift+K and Shift+J from a selected line) gets two filament
// rows. "This part of the layers" comes first: a chip paints the body
// with that filament (zs_app_paint_body: a pick of the lines of the
// body on its layers, see src/body_region.zig). The body shows in the color
// of the filament at once, and the slice follows. "Whole layers" is the
// filament of the layers (project.filament). The filament of the part
// removes the paint of the body.
//
// With a lit body, each other row has a switch: "This part" (the
// default) or "Whole layers". A change for this part goes to the region
// of the body (zs_app_region_set: a modifier volume of the part, see
// src/body_region.zig). A setting that a region cannot have (the walls,
// the fan, the layer height: zs_setting_region_note) stays for the whole
// layers, and its row says why. The search of "+ Add a setting" uses the
// same rule.
//
// One call to the worker opens the card (setScoped with no change
// returns the values too), and one call makes each edit. The card does no
// work for each frame.
//
// Esc, a click elsewhere in the view, or × closes the card and ends the
// light.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { filamentEditor } from "./filaments.js";

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
  // ctx: { browser (SettingsBrowser), host (the slot of the Inspector),
  //        layerZ(l) (the top of
  //        layer l, mm), layerBottom(l), edit(name, value, zmin, zmax,
  //        names) -> Promise<{ error, at }>, reset(name, zmin, zmax,
  //        names) -> Promise<{ at }>, values(zmin, names) -> Promise<at>,
  //        search(text, scope), close(), body() -> true if the range
  //        lights one body, paintBody(filament) -> Promise<error or null>,
  //        addFilament() -> Promise<index>, regionOf() -> Promise<{ id,
  //        values }>, regionSet(id, name, value) -> Promise<{ id, values,
  //        error }> }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.range = null; // [lo, hi], the layers
    this.rows = [];
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
    this.bodyPicked = false;
    if (!this.node) {
      this.build();
      this.ctx.reveal?.();
    }
    const [a, b] = this.range;
    this.title.textContent = a === b ? `Layer ${a + 1}` : `Layers ${a + 1}–${b + 1}`;
    const [z0, z1] = this.zRange();
    this.facts.textContent = `z ${(this.ctx.layerBottom(a)).toFixed(2)} to ${z1.toFixed(2)} mm · ${b - a + 1} ${b === a ? "layer" : "layers"}`;
    const body = !!this.ctx.body?.();
    this.body = body;
    this.bodyRow.hidden = !body;
    this.region = { id: 0, values: {} };
    for (const r of this.rows) this.drawScope(r);
    if (body && this.ctx.regionOf) this.region = (await this.ctx.regionOf()) ?? this.region;
    this.fill(await this.ctx.values(z0, this.names()));
  }

  close() {
    if (!this.node) return;
    this.node.remove();
    this.node = null;
    this.range = null;
    this.bodyPicked = false;
    this.body = false;
    this.region = { id: 0, values: {} };
    this.ctx.close?.();
  }

  build() {
    const card = el("div", "part-card range-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The selected layers");
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title");
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Clear the selection");
    close.title = "Clear the selection (Esc)";
    close.onclick = () => this.close();
    head.append(this.title, close);
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
    // The filament of the lit body (see the header).
    this.bodyRow = el("div", "lc-row range-body");
    const bodyLabel = el("div", "lc-label");
    bodyLabel.append(el("div", "lc-name", "This part of the layers"), el("div", "lc-why", "Filament"));
    bodyLabel.title = "The filament of the lit part of these layers only. The paint of the part keeps it.";
    this.bodyEditor = filamentEditor(
      { name: "body.filament", doc: "A filament for the lit body only" },
      (v) => this.paintBody(Number(v)),
      this.ctx.addFilament ?? this.ctx.browser.ctx?.addFilament ?? null,
    );
    this.bodyRow.append(bodyLabel, this.bodyEditor.node);
    this.box.append(this.bodyRow);
    const byName = this.ctx.browser.byName;
    this.rows = [];
    for (const name of RANGE_SETTINGS) {
      const info = byName.get(name);
      if (info?.perLayer) this.addRow(info);
    }
    this.ctx.host.append(card);
    this.node = card;
  }

  // scope: "part" (the region of the lit body) or "layers"; the default
  // is "part" with a lit body, for a setting that a region can have.
  addRow(info, scope = null) {
    const had = this.rows.find((r) => r.info.name === info.name);
    if (had) {
      if (scope && this.regional(info)) {
        had.scope = scope;
        this.drawScope(had);
      }
      return;
    }
    const row = el("div", "lc-row");
    const label = el("div", "lc-label");
    const name = el("div", "lc-name", info.label);
    const sub = el("div", "lc-why");
    sub.hidden = true;
    label.append(name, sub);
    label.title = info.doc;
    const editor = this.ctx.browser.makeEditor(info, "range", (n, v) => this.set(n, v));
    const reset = el("button", "flat icon pc-clear", "↺");
    reset.title = "Remove the change for these layers";
    reset.setAttribute("aria-label", `${info.label}: remove the change for these layers`);
    reset.onclick = () => this.reset(info.name);
    const scopeBtn = el("button", "flat rc-scope");
    const r = { info, editor, reset, name, sub, scopeBtn, scope: scope ?? "part" };
    scopeBtn.onclick = () => {
      r.scope = r.scope === "part" ? "layers" : "part";
      this.drawScope(r);
      this.fillRow(r);
    };
    row.append(label, scopeBtn, editor.node, reset);
    const note = el("div", "rc-note");
    note.hidden = true;
    r.note = note;
    this.box.append(row, note);
    this.rows.push(r);
    this.drawScope(r);
  }

  // True if a region of some layers can have the setting (no note, and
  // not the filament: the row of the body above it is for that).
  regional(info) {
    return !info.regionNote && info.name !== "project.filament";
  }

  // The scope switch and the note of a row.
  drawScope(r) {
    const fil = r.info.name === "project.filament";
    const can = this.regional(r.info);
    const part = !!this.body && can && r.scope === "part";
    r.scopeBtn.hidden = !this.body || !can;
    r.scopeBtn.textContent = part ? "This part" : "Whole layers";
    r.scopeBtn.classList.toggle("part", part);
    r.scopeBtn.title = part ? "The change is for the lit part of these layers only. Click for the whole layers." : "The change is for the whole layers. Click for the lit part only.";
    r.scopeBtn.setAttribute("aria-label", `${r.info.label}: ${part ? "this part of the layers" : "the whole layers"}`);
    // The filament with a lit body: the row of the whole layers.
    r.name.textContent = fil && this.body ? "Whole layers" : r.info.label;
    r.sub.textContent = fil && this.body ? "Filament" : "";
    r.sub.hidden = !(fil && this.body);
    r.note.textContent = this.body && !can && !fil ? `Whole layers only. ${r.info.regionNote}` : "";
    r.note.hidden = !r.note.textContent;
    r.reset.title = part ? "Remove the change for this part of the layers" : "Remove the change for these layers";
  }

  // True if row r changes the region of the lit body.
  partScope(r) {
    return !!this.body && this.regional(r.info) && r.scope === "part";
  }

  // The value of row r: of the region when it has its own, else of the
  // layers.
  fillRow(r) {
    const entry = this.at?.[r.info.name];
    const own = this.partScope(r) ? this.region?.values?.[r.info.name] : undefined;
    if (own !== undefined) {
      r.editor.update({ ...(entry ?? {}), value: own, over: true });
      r.reset.style.visibility = "visible";
      return;
    }
    if (!entry) return;
    r.editor.update(entry);
    r.reset.style.visibility = entry.over && !this.partScope(r) ? "visible" : "hidden";
  }

  // The values at the first layer: { name: entry } (core.valueAt). The
  // chips of the body start at the filament of the layers.
  fill(at) {
    if (!this.node || !at) return;
    if (!this.bodyPicked && at["project.filament"]) this.bodyEditor.update(at["project.filament"]);
    this.at = at;
    for (const r of this.rows) this.fillRow(r);
  }

  // A change of the region of the lit body (value null: none of its own).
  async setRegion(name, value) {
    const r = await this.ctx.regionSet(this.region?.id ?? 0, name, value);
    if (r.error) return r.error;
    this.region = { id: r.id, values: r.values ?? {} };
    const row = this.rows.find((x) => x.info.name === name);
    if (row) this.fillRow(row);
    return null;
  }

  async set(name, value) {
    if (!this.range) return "No layers.";
    const row = this.rows.find((x) => x.info.name === name);
    if (row && this.partScope(row)) return this.setRegion(name, value);
    const [z0, z1] = this.zRange();
    const r = await this.ctx.edit(name, value, z0, z1, this.names());
    this.fill(r.at);
    return r.error;
  }

  // Paints the lit body with filament `f` (from 1).
  async paintBody(f) {
    if (!this.range) return "No layers.";
    this.bodyPicked = true;
    return (await this.ctx.paintBody(f)) ?? null;
  }

  async reset(name) {
    if (!this.range) return;
    const row = this.rows.find((x) => x.info.name === name);
    if (row && this.partScope(row)) return this.setRegion(name, null);
    const [z0, z1] = this.zRange();
    const r = await this.ctx.reset(name, z0, z1, this.names());
    this.fill(r.at);
  }

  // The search scope of these layers: only the settings that can change
  // for some layers. A setting that the user sets there gets a row.
  scope() {
    const [a, b] = this.range;
    const layers = a === b ? `Layer ${a + 1}` : `Layers ${a + 1}–${b + 1}`;
    // With a lit body, a setting that a region can have goes to this part
    // of the layers; the others go to the whole layers.
    const part = (info) => !!this.body && !!info && this.regional(info);
    return {
      label: this.body ? `${layers}, this part` : layers,
      only: (info) => info.perLayer,
      set: async (name, value) => {
        const info = this.ctx.browser.byName.get(name);
        if (info && this.node) this.addRow(info, part(info) ? "part" : "layers");
        return this.set(name, value);
      },
      value: async (name) => {
        if (!this.range) return null;
        const info = this.ctx.browser.byName.get(name);
        if (part(info)) {
          const own = this.region?.values?.[name];
          if (own !== undefined) return own;
        }
        const at = await this.ctx.values(this.zRange()[0], [name]);
        return at?.[name]?.value ?? null;
      },
      // The part of the layers that the row changes; for the filament,
      // a row for this part of the layers too.
      decorate: (info, row, label) => {
        if (!this.body) return;
        if (info.name === "project.filament") {
          // The editor of the row is for the whole layers; the chips
          // under its label are for this part of the layers.
          label.append(el("div", "lc-why", "Whole layers: the chips at the right"));
          const sub = el("div", "rc-search-body");
          sub.append(el("span", "lc-why", "This part of the layers:"));
          const ed = filamentEditor(
            { name: "body.filament", doc: "A filament for the lit part of these layers only" },
            (v) => this.paintBody(Number(v)),
            this.ctx.addFilament ?? this.ctx.browser.ctx?.addFilament ?? null,
          );
          ed.node.addEventListener("click", (e) => e.stopPropagation());
          sub.append(ed.node);
          label.append(sub);
          return;
        }
        label.append(el("div", "lc-why", part(info) ? "This part of the layers" : `Whole layers only. ${info.regionNote}`));
      },
    };
  }
}
