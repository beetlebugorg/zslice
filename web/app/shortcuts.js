// shortcuts.js: the sheet of the keyboard shortcuts (`?`).
//
// SHORTCUTS is the one table of the keys of the web app. The sheet shows
// it grouped, and an entry at its top filters it. When a key changes in
// app.js (onPreviewKey, the Ctrl keys), tools.js, history.js, or
// search.js, change it here too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

export const SHORTCUTS = [
  {
    group: "General",
    keys: [
      ["?", "Show this sheet of the keyboard shortcuts"],
      ["/", "Search the settings and the actions, and change a setting in the results"],
      ["N", "Show or hide the panel: all settings, the selected line, the history, and the project"],
      ["Ctrl+O", "Open a model"],
      ["Ctrl+E", "Export the G-code"],
      ["Ctrl+Z", "Undo"],
      ["Ctrl+Shift+Z, Ctrl+Y", "Redo"],
      ["Esc", "Close a menu, the search, or this sheet; then clear the measure, then the selection"],
      ["Menu key, Shift+F10", "The menu of the view"],
    ],
  },
  {
    group: "Tools",
    keys: [
      ["S", "Select: a click selects a line"],
      ["M", "Move: a drag moves a part, the wheel turns it 15°"],
      ["T", "Measure: two clicks measure between two points"],
      ["G", "Gaps: show the gaps of the top layer"],
      ["Ctrl+click, Ctrl+drag, Ctrl+wheel", "Select, move, and turn a part with any tool"],
      ["Tab, Shift+Tab", "Select the next part, or the part before"],
      ["Left, Right, Up, Down (a part)", "Move the selected part 1 mm (with Shift: 10 mm)"],
      ["R", "Turn: drag a ring of the selected part to turn it about X, Y, or Z"],
      ["Left, Right (Turn tool)", "Turn the selected part on the bed, 15° (with Shift: 5°)"],
      ["Up, Down (Turn tool)", "Tilt the selected part about X, 15° (with Shift: 5°)"],
      ["Page Up, Page Down (Turn tool)", "Tilt the selected part about Y, 15° (with Shift: 5°)"],
      ["D", "Duplicate the selected part"],
      ["Delete", "Remove the selected part"],
      ["Shift+click", "Add a line to the selection"],
      ["Shift (measure)", "No snap"],
    ],
  },
  {
    group: "Layers",
    keys: [
      ["Up, K", "The top layer one up (with a selected line: the nearest line one layer up)"],
      ["Down, J", "The top layer one down (with a selected line: the nearest line one layer down)"],
      ["Page Up, Page Down", "10 layers up or down"],
      ["Shift+Up, Shift+Down", "Move the bottom of the layer range"],
      ["C", "Show the layers up to the selected line"],
      ["Shift+C", "Show all layers"],
    ],
  },
  {
    group: "Lines and the nozzle",
    keys: [
      ["Left, H", "The segment before the selected one (no selection: the nozzle back 2 % of the layer)"],
      ["Right, L", "The next segment (no selection: the nozzle on 2 % of the layer)"],
      ["Shift+Left, Shift+Right", "The line before, or the next line"],
    ],
  },
  {
    group: "Search",
    keys: [
      ["Up, Down", "Go through the results"],
      ["Left, Right", "Change the value of the result: a step, or the next choice"],
      ["Space, Enter", "Turn a switch, or run an action"],
      ["Tab", "Go into the controls of the result"],
      ["Esc", "Leave a control, then close the search"],
    ],
  },
  {
    group: "History",
    keys: [
      ["Up, Down (History tab)", "The next step, or the step before"],
      ["Left, Right (timeline)", "The step before, or the next step"],
    ],
  },
  {
    group: "Mouse and touchpad",
    keys: [
      ["Left drag", "Orbit"],
      ["Middle or right drag", "Pan (on a touchpad: two fingers pressed down and a drag)"],
      ["Wheel, light two-finger swipe, pinch", "Zoom toward the pointer"],
      ["Double-click on a side of a part", "Lay the part down on that side"],
      ["Double-click elsewhere", "Reset the view"],
      ["Right click", "The menu of the view"],
    ],
  },
];

// The keys of a shortcut as <kbd> elements: "Ctrl+Shift+Z, Ctrl+Y".
function keysNode(text) {
  const box = el("span", "keys-of");
  text.split(", ").forEach((alt, i) => {
    if (i > 0) box.append(el("span", "keys-or", "or"));
    const m = /^(.*?)( \(.*\))?$/.exec(alt);
    m[1].split("+").forEach((k, j) => {
      if (j > 0) box.append(el("span", "keys-plus", "+"));
      box.append(el("kbd", "", k));
    });
    if (m[2]) box.append(el("span", "keys-note", m[2].trim()));
  });
  return box;
}

export class ShortcutSheet {
  constructor() {
    this.root = null;
  }

  get open() {
    return !!this.root;
  }

  toggle() {
    if (this.root) this.close();
    else this.show();
  }

  show() {
    if (this.root) return;
    const shade = el("div", "keys-shade");
    shade.onclick = () => this.close();
    const box = el("div", "keys-box");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Keyboard shortcuts");
    const head = el("div", "keys-head");
    const title = el("div", "keys-title", "Keyboard shortcuts");
    const filter = document.createElement("input");
    filter.className = "keys-filter";
    filter.placeholder = "Filter";
    filter.spellcheck = false;
    filter.setAttribute("aria-label", "Filter the shortcuts");
    const close = el("button", "flat icon", "×");
    close.setAttribute("aria-label", "Close");
    close.onclick = () => this.close();
    head.append(title, filter, close);
    const body = el("div", "keys-body");
    box.append(head, body);
    const fill = () => {
      const q = filter.value.trim().toLowerCase();
      body.replaceChildren();
      for (const g of SHORTCUTS) {
        const rows = g.keys.filter(([k, what]) => !q || k.toLowerCase().includes(q) || what.toLowerCase().includes(q) || g.group.toLowerCase().includes(q));
        if (rows.length === 0) continue;
        const sec = el("section", "keys-group");
        sec.append(el("h3", "", g.group));
        for (const [k, what] of rows) {
          const row = el("div", "keys-row");
          row.append(keysNode(k), el("span", "keys-what", what));
          sec.append(row);
        }
        body.append(sec);
      }
      if (!body.childElementCount) body.append(el("div", "keys-none", "No shortcut matches."));
    };
    filter.addEventListener("input", fill);
    box.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this.close();
      }
    });
    this.root = el("div", "keys-layer");
    this.root.append(shade, box);
    document.body.append(this.root);
    fill();
    filter.focus();
  }

  close() {
    this.root?.remove();
    this.root = null;
  }
}
