// partcard.js: the card of a selected part, next to it in the view
// (docs/internals/one-view.md). The Move tool (or Ctrl+click) selects a
// part, and the card shows:
//
// - its name, its size, and its turn;
// - its actions: Duplicate (D), Split to parts, Cut… (a level plane at a
//   height, shown in the view while the slider moves), Best orientation,
//   Less support, Reset, and Remove (Delete);
// - the settings that the part has of its own (not the values of the
//   plate), each with a live editor and × to give it the value of the
//   plate again. "+ Add a setting for this part" opens the search for the
//   part: only the settings that a part can have, and the edits go to it;
// - its labels: a click on one selects it in the Label tool (label.js).
//
// With several parts selected (Shift and a click), the card shows how
// many, and the actions that work for all of them: Duplicate, Arrange the
// plate, To a new plate, Remove, and a setting for all of them. A drag of
// one of them with the Move tool (or Ctrl), or the arrow keys, moves them
// all. Each action is one call to the worker, and one step of the history.
//
// A change slices at once. The card follows the part when the camera
// moves (app.js calls `place` after each frame), until a drag of its head
// moves it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";
import { spatial, savedPlace, remember } from "./spatial.js";
import { placeBeside, freeArea } from "./place.js";
import { filaments, followFilaments } from "./filaments.js";
import { labelName } from "./label.js";

export class PartCard {
  // ctx: { client, browser (SettingsBrowser), host (the element of the
  //        view), pixelOf(point) -> [px, py] in device pixels or null,
  //        select(part or null), search(text, scope), toast(text) }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.part = null;
    this.parts = [];
    this.many = false; // the card is for several parts
    // A filament that goes renumbers the filaments after it: the
    // filament of the part changes in the core, so the chips read it
    // again.
    let count = filaments().length;
    followFilaments(() => {
      const n = filaments().length;
      if (n < count && this.node && !this.many) this.refreshSettings();
      count = n;
    });
  }

  get open() {
    return !!this.node;
  }

  // The selected part (zs_part of the worker), or null, and all the
  // selected parts (part is the last of them).
  async show(part, parts = part ? [part] : []) {
    if (!part) {
      this.close();
      return;
    }
    if (parts.length > 1) {
      this.showMany(parts);
      return;
    }
    if (this.many) this.close();
    this.parts = [part];
    // The same part again (a drag moves it): only its facts and place.
    const same = this.part && this.part.index === part.index && this.node;
    this.part = part;
    if (!same) this.build();
    this.updateFacts();
    if (!same) {
      this.refreshLabels();
      await this.refreshSettings();
    }
    this.place();
  }

  // The list of the labels of the part.
  async refreshLabels() {
    const part = this.part;
    if (!part || !this.labelBox) return;
    const r = await this.ctx.client.call("labelsGet", { index: part.index });
    if (this.part !== part || !this.labelBox) return;
    const box = this.labelBox;
    const list = r.labels ?? [];
    box.replaceChildren();
    box.hidden = list.length === 0;
    if (list.length === 0) return;
    box.append(el("div", "pc-heading", "Labels"));
    for (const l of list) {
      const b = el("button", "flat", `${labelName(l)} · filament ${l.filament}`);
      b.title = "Select this label in the Label tool (L)";
      b.onclick = () => this.ctx.openLabel?.(part.index, l.id);
      box.append(b);
    }
    this.place();
  }

  close() {
    this.endCut();
    this.userAt = null;
    this.node?.remove();
    this.node = null;
    this.part = null;
    this.parts = [];
    this.many = false;
  }

  // ---- several parts ----

  showMany(parts) {
    const sameSet = this.many && this.node && this.parts.length === parts.length && this.parts.every((p, i) => p.index === parts[i].index);
    this.parts = parts;
    this.part = parts[parts.length - 1];
    if (!sameSet) this.buildMany();
    this.updateMany();
    this.place();
  }

  buildMany() {
    this.endCut();
    this.node?.remove();
    this.many = true;
    const card = el("div", "part-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The selected parts");
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title");
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close (Esc)";
    close.onclick = () => this.ctx.select(null);
    head.append(this.title, close);
    head.title = "Drag to move the card";
    movable(card, head, this.ctx.host, (x, y) => {
      this.userAt = [x, y];
      remember("part-card", { x, y });
    });
    // Its place and size stay for the next card (spatial.js).
    spatial(card, "part-card", head, () => {
      this.userAt = null;
      this.place();
    });
    this.facts = el("div", "lc-size");
    const actions = el("div", "pc-actions");
    const action = (label, key, title, name) => {
      const b = el("button", "pc-action", label);
      b.title = key ? `${title} (${key})` : title;
      b.onclick = () => this.act(name);
      actions.append(b);
    };
    action("Duplicate", "D", "A copy of each part at a free place on the bed", "duplicate");
    action("Arrange the plate", "", "Put all parts of the plate in rows, apart from each other", "arrange");
    const moveB = el("button", "pc-action", "To a new plate");
    moveB.title = "Move these parts to one new plate, with the settings of this plate";
    moveB.onclick = () => this.moveToNewPlate();
    actions.append(moveB);
    action("Remove", "Delete", "Remove these parts from the plate", "remove");
    const hint = el("div", "dim caption", "To move them all: drag one of them with the Move tool (or Ctrl and a drag), or press the arrow keys.");
    const add = el("button", "flat pc-add", "+ Add a setting for these parts");
    add.title = "Search the settings that a part can have of its own: the edit goes to each of these parts";
    add.onclick = () => this.ctx.search("", this.scope());
    this.settingsBox = el("div", "lc-settings");
    this.settingsBox.hidden = true;
    this.cutBox = null;
    card.append(head, this.facts, actions, hint, add);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.ctx.select(null);
      }
    });
    this.ctx.host.append(card);
    this.node = card;
  }

  updateMany() {
    const ps = this.parts;
    this.title.textContent = `${ps.length} parts`;
    const x0 = Math.min(...ps.map((p) => p.x - p.sizeX / 2));
    const x1 = Math.max(...ps.map((p) => p.x + p.sizeX / 2));
    const y0 = Math.min(...ps.map((p) => p.y - p.sizeY / 2));
    const y1 = Math.max(...ps.map((p) => p.y + p.sizeY / 2));
    // The names, each once, with a count: "2 × 3DBenchy.stl".
    const count = new Map();
    for (const p of ps) {
      const name = p.name || `Part ${p.index + 1}`;
      count.set(name, (count.get(name) ?? 0) + 1);
    }
    const names = [...count].map(([name, n]) => (n > 1 ? `${n} × ${name}` : name));
    this.facts.textContent = `${names.join(", ")} · ${(x1 - x0).toFixed(1)} × ${(y1 - y0).toFixed(1)} mm on the bed`;
  }

  build() {
    this.node?.remove();
    const card = el("div", "part-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The selected part");
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title");
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close (Esc)";
    close.onclick = () => this.ctx.select(null);
    head.append(this.title, close);
    head.title = "Drag to move the card";
    movable(card, head, this.ctx.host, (x, y) => {
      this.userAt = [x, y];
      remember("part-card", { x, y });
    });
    // Its place and size stay for the next card (spatial.js).
    spatial(card, "part-card", head, () => {
      this.userAt = null;
      this.place();
    });
    this.facts = el("div", "lc-size");
    const actions = el("div", "pc-actions");
    const action = (label, key, title, name) => {
      const b = el("button", "pc-action", label);
      b.title = key ? `${title} (${key})` : title;
      b.onclick = () => this.act(name);
      actions.append(b);
    };
    action("Duplicate", "D", "A copy of the part at a free place on the bed", "duplicate");
    action("Split to parts", "", "Make each separate body of the part a part of its own, at its place", "split");
    const cutB = el("button", "pc-action", "Cut…");
    cutB.title = "Cut the part in two with a level plane";
    cutB.onclick = () => this.toggleCut();
    actions.append(cutB);
    action("Best orientation", "", "Turn the part to its best orientation: less support, more on the bed, low", "smart");
    action("Less support", "", "Turn the part to need the least support", "less-support");
    // The scale, in % of the file, the same along each axis.
    const scaleRow = el("label", "pc-cut-row pc-scale");
    this.scaleIn = Object.assign(document.createElement("input"), { type: "number", min: "1", max: "100000", step: "any", className: "pc-cut-n" });
    this.scaleIn.title = "The size of the part, in % of the file (Enter applies)";
    const applyScale = async () => {
      const v = Number(this.scaleIn.value);
      if (!(v > 0) || !this.part) return;
      const r = await this.ctx.client.call("partScale", { index: this.part.index, s: v / 100 });
      if (r.part) this.show(r.part);
    };
    this.scaleIn.onkeydown = (e) => { if (e.key === "Enter") applyScale(); e.stopPropagation(); };
    this.scaleIn.onchange = applyScale;
    scaleRow.append("Scale ", this.scaleIn, " %");
    actions.append(scaleRow);
    action("Reset", "", "The orientation and the scale of the file again", "reset");
    const moveB = el("button", "pc-action", "To a new plate");
    moveB.title = "Move the part to a new plate, with the settings of this plate";
    moveB.onclick = () => this.moveToNewPlate();
    actions.append(moveB);
    action("Remove", "Delete", "Remove the part from the plate", "remove");
    // Make n in all: copies on this plate, then on new plates.
    const make = el("div", "pc-cut-row pc-make");
    const makeN = Object.assign(document.createElement("input"), { type: "number", min: "2", max: "10000", step: "1", value: "10", className: "pc-cut-n" });
    makeN.setAttribute("aria-label", "How many of this part to make");
    const makeB = el("button", "pc-action", "Make");
    makeB.title = "Copies of the part until there are this many in all: on this plate while they fit, then on new plates with the same settings";
    makeB.onclick = () => this.fill(Math.max(2, Math.min(10000, Number(makeN.value) || 2)));
    make.append(el("span", "", "Make"), makeN, el("span", "dim", "in all"), makeB);
    this.cutBox = el("div", "pc-cut");
    this.cutBox.hidden = true;
    this.settingsBox = el("div", "lc-settings");
    const add = el("button", "flat pc-add", "+ Add a setting for this part");
    add.title = "Search the settings that a part can have of its own";
    add.onclick = () => this.ctx.search("", this.scope());
    // The filament of the part (or of the selected parts): a chip for
    // each filament of the plate (filaments.js).
    const filRow = el("div", "lc-row pc-filament");
    const filLabel = el("div", "lc-label");
    filLabel.append(el("div", "lc-name", "Filament"));
    const filInfo = this.ctx.browser.byName.get("project.filament");
    this.filEd = filInfo ? this.ctx.browser.makeEditor(filInfo, "part", (n, v) => this.scope().set(n, v)) : null;
    filLabel.title = filInfo?.doc ?? "";
    if (this.filEd) filRow.append(filLabel, this.filEd.node);
    // The labels of the part (label.js): a click selects one in the Label
    // tool.
    this.labelBox = el("div", "pc-labels");
    this.labelBox.hidden = true;
    card.append(head, this.facts, filRow, actions, make, this.cutBox, this.labelBox, this.settingsBox, add);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.ctx.select(null);
      }
    });
    this.ctx.host.append(card);
    this.node = card;
  }

  // ---- the cut ----

  // Opens the row of the cut: the height (a slider and a number), the flip,
  // and Cut. The plane shows in the view while the row is open.
  toggleCut() {
    if (!this.cutBox.hidden) {
      this.endCut();
      return;
    }
    const p = this.part;
    const box = this.cutBox;
    box.replaceChildren();
    const h = el("label", "pc-cut-row");
    h.append(el("span", "", "Height"));
    const slider = Object.assign(document.createElement("input"), { type: "range", min: "0.2", max: String(Math.max(0.4, p.sizeZ - 0.2)), step: "0.1", value: String((p.sizeZ / 2).toFixed(1)) });
    const num = Object.assign(document.createElement("input"), { type: "number", min: slider.min, max: slider.max, step: "0.1", value: slider.value, className: "pc-cut-n" });
    num.setAttribute("aria-label", "The height of the cut, mm");
    h.append(slider, num, el("span", "dim", "mm"));
    const flipL = el("label", "pc-cut-row");
    const flip = Object.assign(document.createElement("input"), { type: "checkbox", checked: true });
    flipL.append(flip, el("span", "", "Turn the top over (it prints on its cut face)"));
    // Pegs: holes in both cut faces, and the pegs as parts, to line the
    // parts up when they are glued.
    const pegL = el("label", "pc-cut-row");
    const pegOn = Object.assign(document.createElement("input"), { type: "checkbox", checked: true });
    const pegN = document.createElement("select");
    for (const n of [1, 2, 3, 4]) pegN.append(new Option(String(n), String(n), false, n === 2));
    pegN.setAttribute("aria-label", "The most pegs");
    const pegD = Object.assign(document.createElement("input"), { type: "number", min: "2", max: "20", step: "0.5", value: "5", className: "pc-cut-n" });
    pegD.setAttribute("aria-label", "The diameter of a peg, mm");
    pegL.title = "Holes in both cut faces, and pegs that print as parts of their own. Glue the pegs into the holes: the parts line up. A peg goes only where the part is wide and deep enough.";
    pegL.append(pegOn, el("span", "", "Pegs to line up the parts:"), pegN, el("span", "", "of"), pegD, el("span", "dim", "mm"));
    const go = el("button", "pc-action", "Cut");
    const cancel = el("button", "flat", "Cancel");
    const row = el("div", "pc-cut-row");
    row.append(go, cancel);
    box.append(h, flipL, pegL, row);
    box.hidden = false;
    const show = () => {
      const z = Number(num.value) || 0;
      this.ctx.cutPlane?.([p.x - p.sizeX / 2 - 3, p.y - p.sizeY / 2 - 3, p.x + p.sizeX / 2 + 3, p.y + p.sizeY / 2 + 3, z]);
    };
    slider.oninput = () => {
      num.value = slider.value;
      show();
    };
    num.oninput = () => {
      slider.value = num.value;
      show();
    };
    cancel.onclick = () => this.endCut();
    go.onclick = async () => {
      const r = await this.ctx.client.call("partCut", { index: p.index, z: Number(num.value), flip: flip.checked, pegs: pegOn.checked ? Number(pegN.value) : 0, pegD: Number(pegD.value) || 5 });
      this.endCut();
      if (!r.ok) {
        this.ctx.toast(r.message);
        return;
      }
      let text = "Cut into two parts.";
      if (pegOn.checked && r.pegs === 0) text = "Cut into two parts. No peg fits: the cut is too small or too thin for one.";
      else if (r.pegs > 0) text = `Cut into two parts, with ${r.pegs} ${r.pegs === 1 ? "peg" : "pegs"}. Glue the pegs into the holes to join the parts.`;
      if (!r.fits) text += " The parts do not all fit on this bed: they overlap now. Select a part, and click To a new plate.";
      this.ctx.toast(text);
      this.ctx.select(r.part);
    };
    show();
    this.place();
  }

  async fill(n) {
    if (!this.part) return;
    const r = await this.ctx.fillPart?.(this.part.index, n);
    if (!r?.ok) {
      this.ctx.toast("No copies were made.");
      return;
    }
    const plates = r.plates === 1 ? "this plate" : `${r.plates} plates`;
    this.ctx.toast(r.copies < n ? `${r.copies} of ${n} fit: the part is too big for more plates.` : `${r.copies} in all, on ${plates}.`);
    this.ctx.select(null);
  }

  async moveToNewPlate() {
    if (!this.part) return;
    if (this.many) {
      const r = await this.ctx.client.call("partsToPlate", { indices: this.parts.map((p) => p.index) });
      if (!r?.ok) {
        this.ctx.toast("The parts did not move.");
        return;
      }
      this.ctx.toast(`Moved ${this.parts.length} parts to plate ${r.to + 1}.`);
      this.ctx.select(null);
      return;
    }
    const r = await this.ctx.movePart?.(this.part.index, -1);
    if (!r?.ok) {
      this.ctx.toast("The part did not move.");
      return;
    }
    this.ctx.toast(`Moved to plate ${r.to + 1}.`);
    this.ctx.select(null);
  }

  endCut() {
    if (!this.cutBox || this.cutBox.hidden) return;
    this.cutBox.hidden = true;
    this.cutBox.replaceChildren();
    this.ctx.cutPlane?.(null);
    this.place();
  }

  updateFacts() {
    const p = this.part;
    this.title.textContent = p.name || `Part ${p.index + 1}`;
    const turn = Math.round(((p.rotation % 360) + 360) % 360);
    if (this.scaleIn && document.activeElement !== this.scaleIn && p.scale) this.scaleIn.value = String(Math.round(p.scale[0] * 10000) / 100);
    this.facts.textContent = `${p.sizeX.toFixed(1)} × ${p.sizeY.toFixed(1)} × ${p.sizeZ.toFixed(1)} mm${turn ? ` · turned ${turn}°` : ""}`;
  }

  // The search scope of this part, or of all the selected parts.
  scope() {
    if (this.many) {
      const indices = this.parts.map((p) => p.index);
      return {
        label: `${indices.length} parts`,
        set: async (name, value) => {
          const r = await this.ctx.client.call("partsSettingSet", { indices, name, value });
          if (r.error) this.ctx.toast(r.error);
          return r.error;
        },
        value: async (name) => {
          const r = await this.ctx.client.call("partSettings", { index: indices[0] });
          return r.list.find(([n]) => n === name)?.[1] ?? null;
        },
      };
    }
    const index = this.part.index;
    return {
      label: `Part: ${this.part.name || index + 1}`,
      set: (name, value) => this.setSetting(name, value),
      value: async (name) => {
        const r = await this.ctx.client.call("partSettings", { index });
        return r.list.find(([n]) => n === name)?.[1] ?? null;
      },
    };
  }

  async setSetting(name, value) {
    if (!this.part) return "No part.";
    const r = await this.ctx.client.call("partSettingSet", { index: this.part.index, name, value });
    if (r.error) this.ctx.toast(r.error);
    this.fillSettings(r.list);
    return r.error;
  }

  async refreshSettings() {
    if (!this.part) return;
    const r = await this.ctx.client.call("partSettings", { index: this.part.index });
    this.fillSettings(r.list);
  }

  // The rows of the settings of the part, each with its editor.
  fillSettings(list) {
    if (!this.node) return;
    const box = this.settingsBox;
    const byName = this.ctx.browser.byName;
    // The filament has its own row of chips at the top of the card.
    const fil = list.find(([name]) => name === "project.filament");
    this.filEd?.update({ value: fil ? fil[1] : this.ctx.browser.values?.["project.filament"]?.value ?? "1" });
    const rows = list.filter(([name]) => byName.has(name) && name !== "project.filament");
    box.replaceChildren();
    box.hidden = rows.length === 0;
    if (rows.length === 0) return;
    box.append(el("div", "pc-heading", "Settings of this part"));
    for (const [name, value] of rows) {
      const info = byName.get(name);
      const row = el("div", "lc-row");
      const label = el("div", "lc-label");
      label.append(el("div", "lc-name", info.label));
      label.title = info.doc;
      const ed = this.ctx.browser.makeEditor(info, "part", (n, v) => this.setSetting(n, v));
      ed.update({ value, level: 6 });
      const clear = el("button", "flat icon pc-clear", "×");
      clear.title = "The value of the plate again";
      clear.setAttribute("aria-label", `${info.label}: the value of the plate again`);
      clear.onclick = () => this.setSetting(name, null);
      row.append(label, ed.node, clear);
      box.append(row);
    }
    this.place();
  }

  async act(action) {
    if (!this.part) return;
    if (this.many) {
      const r = await this.ctx.client.call("partsAction", { indices: this.parts.map((p) => p.index), action });
      if (!r.ok) {
        this.ctx.toast("The parts did not change.");
        return;
      }
      // The copies are the new selection; after Remove, none.
      if (action === "arrange") this.ctx.select(null);
      else this.ctx.selectMany?.(r.parts);
      return;
    }
    const r = await this.ctx.client.call("partAction", { index: this.part.index, action });
    if (!r.ok) {
      this.ctx.toast(r.message ?? "The part did not change.");
      return;
    }
    if (action === "split") this.ctx.toast(`Split into ${r.count} parts.`);
    this.ctx.select(r.part);
  }

  // Next to the part (or the parts), over the right of its top, inside
  // the view.
  place() {
    const card = this.node;
    if (!card || !this.part) return;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
    const dpr = window.devicePixelRatio || 1;
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    for (const p of this.parts.length > 0 ? this.parts : [this.part]) this.addBox(p, box, dpr);
    // The place where the user put the card before, if it is clear of
    // what the card is about.
    const kept = savedPlace("part-card", card, this.ctx.host, box[0] <= box[2] ? box : null);
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

  // Grows box (CSS pixels) by the box of part p on the screen.
  addBox(p, box, dpr) {
    // The box of the part on the screen, with the rings of the Turn tool
    // (turn.js: radius 0.62 of the largest size, and 4 mm): the card
    // covers no part of them.
    const ring = 0.62 * Math.max(p.sizeX, p.sizeY, p.sizeZ) + 4;
    const hx = Math.max(p.sizeX / 2, ring);
    const hy = Math.max(p.sizeY / 2, ring);
    const zTop = Math.max(p.sizeZ, p.sizeZ / 2 + ring);
    for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const z of [0, zTop]) {
      const q = this.ctx.pixelOf({ x: p.x + sx * hx, y: p.y + sy * hy, z });
      if (!q) continue;
      box[0] = Math.min(box[0], q[0] / dpr);
      box[1] = Math.min(box[1], q[1] / dpr);
      box[2] = Math.max(box[2], q[0] / dpr);
      box[3] = Math.max(box[3], q[1] / dpr);
    }
  }
}
