// partcard.js: the card of a selected part, next to it in the view
// (docs/internals/one-view.md). The Move tool (or Ctrl+click) selects a
// part, and the card shows:
//
// - its name, its size, and its turn;
// - its actions: Duplicate (D), Best orientation, Less support, Reset, and
//   Remove (Delete);
// - the settings that the part has of its own (not the values of the
//   plate), each with a live editor and × to give it the value of the
//   plate again. "+ Add a setting for this part" opens the search for the
//   part: only the settings that a part can have, and the edits go to it.
//
// A change slices at once. The card follows the part when the camera
// moves (app.js calls `place` after each frame), until a drag of its head
// moves it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";

export class PartCard {
  // ctx: { client, browser (SettingsBrowser), host (the element of the
  //        view), pixelOf(point) -> [px, py] in device pixels or null,
  //        select(part or null), search(text, scope), toast(text) }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.part = null;
  }

  get open() {
    return !!this.node;
  }

  // The selected part (zs_part of the worker), or null.
  async show(part) {
    if (!part) {
      this.close();
      return;
    }
    // The same part again (a drag moves it): only its facts and place.
    const same = this.part && this.part.index === part.index && this.node;
    this.part = part;
    if (!same) this.build();
    this.updateFacts();
    if (!same) await this.refreshSettings();
    this.place();
  }

  close() {
    this.userAt = null;
    this.node?.remove();
    this.node = null;
    this.part = null;
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
    action("Best orientation", "", "Turn the part to its best orientation: less support, more on the bed, low", "smart");
    action("Less support", "", "Turn the part to need the least support", "less-support");
    action("Reset", "", "The orientation and the scale of the file again", "reset");
    action("Remove", "Delete", "Remove the part from the plate", "remove");
    this.settingsBox = el("div", "lc-settings");
    const add = el("button", "flat pc-add", "+ Add a setting for this part");
    add.title = "Search the settings that a part can have of its own";
    add.onclick = () => this.ctx.search("", this.scope());
    card.append(head, this.facts, actions, this.settingsBox, add);
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

  updateFacts() {
    const p = this.part;
    this.title.textContent = p.name || `Part ${p.index + 1}`;
    const turn = Math.round(((p.rotation % 360) + 360) % 360);
    this.facts.textContent = `${p.sizeX.toFixed(1)} × ${p.sizeY.toFixed(1)} × ${p.sizeZ.toFixed(1)} mm${turn ? ` · turned ${turn}°` : ""}`;
  }

  // The search scope of this part.
  scope() {
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
    const rows = list.filter(([name]) => byName.has(name));
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
    const r = await this.ctx.client.call("partAction", { index: this.part.index, action });
    if (!r.ok) {
      this.ctx.toast("The part did not change.");
      return;
    }
    this.ctx.select(r.part);
  }

  // Next to the part, over the right of its top, inside the view.
  place() {
    const card = this.node;
    const p = this.part;
    if (!card || !p) return;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
    const dpr = window.devicePixelRatio || 1;
    // Past the rings of the Turn tool (turn.js: radius 0.62 of the
    // largest size, and 4 mm), so the card covers none of them.
    const ring = 0.62 * Math.max(p.sizeX, p.sizeY, p.sizeZ) + 4;
    const q = this.ctx.pixelOf({ x: p.x + Math.max(p.sizeX / 2, ring) + 6, y: p.y, z: p.sizeZ / 2 });
    const host = this.ctx.host.getBoundingClientRect();
    const w = card.offsetWidth;
    const h = card.offsetHeight;
    let x = q ? q[0] / dpr + 24 : host.width - w - 70;
    let y = q ? q[1] / dpr - h / 2 : 80;
    if (x + w > host.width - 60) x = (q ? q[0] / dpr : host.width) - w - 24;
    x = Math.max(62, Math.min(host.width - w - 8, x));
    y = Math.max(60, Math.min(host.height - h - 140, y));
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }
}
