// dock.js: the Inspector, a column of the window beside the view
// (docs/internals/one-view.md). The view gets the rest of the window, so
// no panel of a selection can draw over the 3D or the 2D view.
//
// The cards of a part, a line, a range of layers, a label, the Paint tool,
// and the Support tool all mount in one slot. The slot shows one card: the
// first in ORDER that is not hidden. With no card, the Inspector shows the
// summary of the plate. A selection only changes this content. It never
// opens, closes, or resizes the column.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

// The most specific card comes first.
const ORDER = ["label-card", "paint-card", "support-card", "range-card", "part-card", "line-card"];
const GROUPS_KEY = "zslice.inspector.groups";
// The most parts in the list of the plate.
const MAX_LISTED = 60;

function loadGroups() {
  try {
    return JSON.parse(localStorage.getItem(GROUPS_KEY)) ?? {};
  } catch {
    return {};
  }
}

// A group of the Inspector that the user can collapse. Its state stays
// in this browser, by its title.
export function group(title, ...nodes) {
  const box = el("details", "insp-group");
  box.open = loadGroups()[title] !== false;
  box.append(el("summary", "insp-group-title", title), ...nodes);
  box.addEventListener("toggle", () => {
    const all = loadGroups();
    all[title] = box.open;
    try {
      localStorage.setItem(GROUPS_KEY, JSON.stringify(all));
    } catch {
      // No storage: the state lasts until a reload.
    }
  });
  return box;
}

export class InspectorDock {
  // slot: the element of the cards. plate: the element of the summary.
  // ctx: { summary() -> { title, facts, parts: [{ id, name, size }] },
  //        selectPart(id), changed(hasSelection) }
  constructor(slot, plate, ctx) {
    this.slot = slot;
    this.plate = plate;
    this.ctx = ctx;
    this.queued = false;
    new MutationObserver(() => this.refresh()).observe(slot, { childList: true, subtree: true, attributes: true, attributeFilter: ["hidden"] });
    this.refresh();
  }

  // The card that shows now, or null.
  current() {
    const cards = [...this.slot.children].filter((c) => !c.hidden);
    for (const kind of ORDER) {
      const c = cards.find((x) => x.classList.contains(kind));
      if (c) return c;
    }
    return null;
  }

  refresh() {
    const now = this.current();
    for (const c of this.slot.children) c.classList.toggle("insp-behind", c !== now);
    // The observer sees each write of `hidden`, also of the same value.
    if (this.slot.hidden !== !now) this.slot.hidden = !now;
    this.plate.hidden = !!now;
    if (!now) this.fillPlate();
    this.ctx.changed?.(!!now);
  }

  // Asks for a new summary of the plate, at most once for each frame.
  plateChanged() {
    if (this.queued) return;
    this.queued = true;
    requestAnimationFrame(() => {
      this.queued = false;
      if (!this.plate.hidden) this.fillPlate();
    });
  }

  fillPlate() {
    const s = this.ctx.summary?.();
    if (!s) return;
    const box = el("div", "insp-plate-body");
    box.append(el("div", "lc-title", s.title));
    if (s.facts) box.append(el("div", "lc-size", s.facts));
    if (s.parts.length > 0) {
      const list = el("div", "insp-parts");
      for (const p of s.parts.slice(0, MAX_LISTED)) {
        const b = el("button", "flat insp-part");
        b.append(el("span", "insp-part-name", p.name), el("span", "dim insp-part-size", p.size));
        b.title = "Select this part";
        b.onclick = () => this.ctx.selectPart(p.id);
        list.append(b);
      }
      box.append(group("Parts", list));
      if (s.parts.length > MAX_LISTED) box.append(el("div", "dim caption", `And ${s.parts.length - MAX_LISTED} more parts.`));
    }
    box.append(el("div", "dim caption", s.parts.length > 0 ? "Select a part or a line in the view to see it here." : "Open a model to start."));
    this.plate.replaceChildren(box);
  }
}
