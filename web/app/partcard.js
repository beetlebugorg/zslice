// partcard.js: the Inspector page of a selected part (dock.js,
// docs/internals/one-view.md). The Move tool (or Ctrl+click) selects a
// part, and the card shows:
//
// - its name and its size;
// - its pose: the place X and Y, the lift Z (up: it floats; down: it sinks
//   into the bed), and the turns about X, Y, and Z, each a number field
//   (Enter applies), and why it floats when it does;
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
// A change slices at once.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { group } from "./dock.js";
import { displayValue } from "./format.js";
import { filaments, followFilaments } from "./filaments.js";
import { labelName } from "./label.js";

export class PartCard {
  // ctx: { client, browser (SettingsBrowser), host (the slot of the
  //        Inspector), select(part or null), search(text, scope), toast(text) }
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
    const same = this.part && this.part.id === part.id && this.node;
    this.part = part;
    if (!same) this.build();
    this.updateFacts();
    if (!same) {
      this.refreshLabels();
      await this.refreshSettings();
    }
  }

  // The list of the labels of the part.
  async refreshLabels() {
    const part = this.part;
    if (!part || !this.labelBox) return;
    const r = await this.ctx.client.call("labelsGet", { index: part.index });
    if (this.part?.id !== part.id || !this.labelBox) return;
    const box = this.labelBox;
    const list = r.labels ?? [];
    box.replaceChildren();
    box.hidden = list.length === 0;
    if (list.length === 0) return;
    box.append(el("div", "pc-heading", "Labels"));
    for (const l of list) {
      const b = el("button", "flat", `${labelName(l)} · filament ${l.filament}`);
      b.title = "Select this label in the Label tool (E)";
      b.onclick = () => this.ctx.openLabel?.(part.index, l.id);
      box.append(b);
    }
  }

  close() {
    this.endCut();
    this.node?.remove();
    this.node = null;
    this.part = null;
    this.parts = [];
    this.many = false;
  }

  // ---- several parts ----

  showMany(parts) {
    const sameSet = this.many && this.node && this.parts.length === parts.length && this.parts.every((p, i) => p.id === parts[i].id);
    this.parts = parts;
    this.part = parts[parts.length - 1];
    if (!sameSet) this.buildMany();
    this.updateMany();
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
    close.setAttribute("aria-label", "Clear the selection");
    close.title = "Clear the selection (Esc)";
    close.onclick = () => this.ctx.select(null);
    head.append(this.title, close);
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
    close.setAttribute("aria-label", "Clear the selection");
    close.title = "Clear the selection (Esc)";
    close.onclick = () => this.ctx.select(null);
    head.append(this.title, close);
    this.facts = el("div", "lc-size");
    // The pose: a number field for each value (Enter or a change applies).
    this.pose = el("div", "pc-pose");
    this.poseIn = {};
    const field = (key, label, unit, title) => {
      const l = el("label", "pc-pose-f");
      const i = Object.assign(document.createElement("input"), { type: "number", step: "any", className: "pc-pose-n" });
      i.title = title;
      i.setAttribute("aria-label", title);
      i.onkeydown = (e) => {
        if (e.key === "Enter") this.applyPose(key);
        e.stopPropagation();
      };
      i.onchange = () => this.applyPose(key);
      this.poseIn[key] = i;
      l.append(el("span", "pc-pose-l", label), i);
      this.pose.append(l);
    };
    field("x", "X", "mm", "The place of the center of the part along X of the bed, mm");
    field("y", "Y", "mm", "The place of the center of the part along Y of the bed, mm");
    field("z", "Z", "mm", "The lift: the bottom of the part over the bed, mm. Over 0 it floats (it prints on support); under 0 it sinks into the bed, and the part under the bed does not print");
    field("ax", "↻X", "°", "The turn about the X axis of the bed, degrees");
    field("ay", "↻Y", "°", "The turn about the Y axis of the bed, degrees");
    field("az", "↻Z", "°", "The turn about the Z axis of the bed, degrees");
    this.note = el("div", "pc-note");
    this.note.hidden = true;
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
    // The size, in % of the file, the same along each axis. The field
    // shows the size with no sign. The Mirrored mark shows the mirror.
    const sizeRow = el("label", "pc-cut-row pc-scale");
    this.scaleIn = Object.assign(document.createElement("input"), { type: "number", min: "1", max: "100000", step: "any", className: "pc-scale-n" });
    this.scaleIn.title = "The size of the part, in % of the file (Enter applies). A mirrored part stays mirrored.";
    const applyScale = async () => {
      const v = Number(this.scaleIn.value);
      if (!(v > 0) || !this.part) return;
      const r = await this.ctx.client.call("partScale", { index: this.part.index, s: v / 100 });
      if (r.part) this.ctx.update(r.part);
    };
    this.scaleIn.onkeydown = (e) => { if (e.key === "Enter") applyScale(); e.stopPropagation(); };
    this.scaleIn.onchange = applyScale;
    this.mirrorMark = el("span", "pc-mirrored", "Mirrored");
    this.mirrorMark.title = "This part is a mirror image of its file. Mirror X or Mirror Y again, or Reset, removes the mirror.";
    this.mirrorMark.hidden = true;
    sizeRow.append(el("span", "pc-scale-l", "Scale"), this.scaleIn, el("span", "dim", "%"), this.mirrorMark);
    this.mirrorNote = el("div", "dim caption");
    this.mirrorNote.hidden = true;
    const sizeActions = el("div", "pc-actions");
    const sized = (label, title, name) => {
      const b = el("button", "pc-action", label);
      b.title = title;
      b.onclick = () => this.act(name);
      sizeActions.append(b);
    };
    sized("Mirror X", "Mirror the part from left to right", "mirror-x");
    sized("Mirror Y", "Mirror the part from front to back", "mirror-y");
    sized("Reset", "The orientation and the scale of the file again", "reset");
    const moveB = el("button", "pc-action", "To a new plate");
    moveB.title = "Move the part to a new plate, with the settings of this plate";
    moveB.onclick = () => this.moveToNewPlate();
    actions.append(moveB);
    action("Remove", "Delete", "Remove the part from the plate", "remove");
    // One part at a time: the place of the part in the print order.
    this.orderRow = el("div", "pc-cut-row pc-order");
    this.orderRow.hidden = true;
    this.orderText = el("span", "", "");
    const earlier = el("button", "pc-action", "Print earlier");
    earlier.title = "Print this part before the part before it in the plate list";
    earlier.onclick = () => this.act("earlier");
    const later = el("button", "pc-action", "Print later");
    later.title = "Print this part after the part after it in the plate list";
    later.onclick = () => this.act("later");
    this.orderRow.append(this.orderText, earlier, later);
    actions.append(this.orderRow);
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
    // The settings of the modifier volumes of the part: each volume is a
    // region of its own, so its values are not values of the part.
    this.volumeBox = el("div", "pc-volumes");
    this.volumeBox.hidden = true;
    const add = el("button", "flat pc-add", "+ Add a setting for this part");
    add.title = "Search the settings that a part can have of its own";
    add.onclick = () => this.ctx.search("", this.scope());
    // The filament of the part (or of the selected parts): a chip for
    // each filament of the plate (filaments.js).
    const filRow = el("div", "lc-row pc-filament");
    const filInfo = this.ctx.browser.byName.get("project.filament");
    this.filEd = filInfo ? this.ctx.browser.makeEditor(filInfo, "part", (n, v) => this.scope().set(n, v)) : null;
    filRow.title = filInfo?.doc ?? "";
    if (this.filEd) filRow.append(this.filEd.node);
    // The labels of the part (label.js): a click selects one in the Label
    // tool.
    this.labelBox = el("div", "pc-labels");
    this.labelBox.hidden = true;
    card.append(
      head,
      this.facts,
      group("Position and turn", this.pose, this.note),
      group("Size and mirror", sizeRow, this.mirrorNote, sizeActions),
      group("Filament", filRow),
      group("Actions", actions, make, this.cutBox),
      this.labelBox,
      group("Settings of this part", this.settingsBox, this.volumeBox, add),
    );
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
      const stamp = this.ctx.stamp();
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
      this.ctx.selectReply(r.part ? [r.part] : [], stamp);
    };
    show();
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
  }

  updateFacts() {
    const p = this.part;
    this.title.textContent = p.name || `Part ${p.index + 1}`;
    this.updateScale(p);
    this.facts.textContent = `${p.sizeX.toFixed(1)} × ${p.sizeY.toFixed(1)} × ${p.sizeZ.toFixed(1)} mm`;
    // The pose: a field that has the focus keeps what the user types.
    const a = p.angles ?? [0, 0, p.rotation ?? 0];
    const vals = { x: p.x, y: p.y, z: p.z ?? 0, ax: a[0], ay: a[1], az: a[2] };
    for (const [k, i] of Object.entries(this.poseIn ?? {})) {
      if (document.activeElement === i) continue;
      const v = vals[k];
      i.value = String(Math.round(v * 100) / 100 || 0);
    }
    this.note.textContent = p.note ?? "";
    this.note.hidden = !p.note;
    this.updateOrder();
  }

  // The size with no sign, and a clear mark for a mirrored part. An odd
  // count of negative axes is a mirror image.
  updateScale(p) {
    if (!this.scaleIn || !p.scale) return;
    const pct = (v) => Math.round(Math.abs(v) * 10000) / 100;
    if (document.activeElement !== this.scaleIn) this.scaleIn.value = String(pct(p.scale[0]));
    const mirrored = p.scale.filter((v) => v < 0).length % 2 === 1;
    this.mirrorMark.hidden = !mirrored;
    const even = pct(p.scale[0]) === pct(p.scale[1]) && pct(p.scale[1]) === pct(p.scale[2]);
    this.mirrorNote.textContent = even ? "" : `Each axis has its own size: X ${pct(p.scale[0])} %, Y ${pct(p.scale[1])} %, Z ${pct(p.scale[2])} %. A new scale sets all three.`;
    this.mirrorNote.hidden = even;
  }

  // The pose field `key` applies: one call, one step of the history.
  async applyPose(key) {
    const p = this.part;
    const i = this.poseIn[key];
    if (!p || !i) return;
    const v = Number(i.value);
    if (!Number.isFinite(v)) return;
    let r;
    if (key === "x" || key === "y") r = await this.ctx.client.call("partMove", { index: p.index, x: key === "x" ? v : p.x, y: key === "y" ? v : p.y });
    else if (key === "z") r = await this.ctx.client.call("partLift", { index: p.index, z: v });
    else {
      const a = [...(p.angles ?? [0, 0, p.rotation ?? 0])];
      a[{ ax: 0, ay: 1, az: 2 }[key]] = v;
      r = await this.ctx.client.call("partAngles", { index: p.index, angles: a });
    }
    if (r?.part) this.ctx.update(r.part);
    // A part in the air with no support falls (the toast says why), and a
    // part on an edge tips over.
    if (key !== "x" && key !== "y") this.ctx.settle?.(p.index);
  }

  // The place of the part in the print order, with one part at a time.
  async updateOrder() {
    const p = this.part;
    if (!p || !this.orderRow) return;
    const r = await this.ctx.client.call("partOrder", { index: p.index });
    if (this.part !== p || !this.orderRow) return;
    this.orderRow.hidden = !r.sequential || r.count < 2;
    this.orderText.textContent = `Prints ${r.index + 1} of ${r.count}`;
    const [earlier, later] = this.orderRow.querySelectorAll("button");
    earlier.disabled = r.index === 0;
    later.disabled = r.index >= r.count - 1;
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
    this.fillVolumes(r.volumes ?? []);
  }

  // The settings of the modifier volumes, by volume. The Inspector of the
  // layers edits them: select the layers of the region.
  fillVolumes(volumes) {
    const box = this.volumeBox;
    if (!box) return;
    const byName = this.ctx.browser.byName;
    const shown = volumes.filter((v) => v.list.some(([name]) => byName.has(name)));
    box.replaceChildren();
    box.hidden = shown.length === 0;
    for (const v of shown) {
      box.append(el("div", "pc-heading", `Region: ${v.name}`));
      for (const [name, value] of v.list) {
        const info = byName.get(name);
        if (!info) continue;
        const row = el("div", "lc-row pc-volume-row");
        row.title = "This value is for this region only. Drag over its layers to change it.";
        row.append(el("div", "lc-name", info.label), el("div", "dim", displayValue(info, value)));
        box.append(row);
      }
    }
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
  }

  async act(action) {
    if (!this.part) return;
    if (this.many) {
      const stamp = this.ctx.stamp();
      const r = await this.ctx.client.call("partsAction", { indices: this.parts.map((p) => p.index), action });
      if (!r.ok) {
        this.ctx.toast("The parts did not change.");
        return;
      }
      // The copies are the new selection; after Remove, none.
      if (action === "arrange") this.ctx.select(null);
      else this.ctx.selectReply(r.parts ?? [], stamp);
      return;
    }
    const stamp = this.ctx.stamp();
    const r = await this.ctx.client.call("partAction", { index: this.part.index, action });
    if (!r.ok) {
      this.ctx.toast(r.message ?? "The part did not change.");
      return;
    }
    if (action === "split") this.ctx.toast(`Split into ${r.count} parts.`);
    this.ctx.selectReply(r.part ? [r.part] : [], stamp);
  }
}
