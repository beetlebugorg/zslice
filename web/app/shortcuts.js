// shortcuts.js: the sheet of the keyboard shortcuts (`?`).
//
// SHORTCUTS is the one table of the keys of the web app. The sheet shows
// it grouped, and an entry at its top filters it. When a key changes in
// app.js (onPreviewKey, the Ctrl keys), tools.js, support.js, history.js,
// or search.js, change it here too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

export const SHORTCUTS = [
  {
    group: "General",
    keys: [
      ["?", "Show this sheet of the keyboard shortcuts"],
      ["/", "Search the settings and the actions, and change a setting in the results"],
      ["N", "Show or hide the panel of the settings (and the selected line, from All settings on its card)"],
      ["2", "The 2D layer view, or the 3D view again (also in the main menu: 2D view)"],
      ["B", "Hide the bed and its grid, or show them again: the bottom of a part shows from below (also in the main menu)"],
      ["3", "The 3D view"],
      ["Ctrl+O", "Open a model or a project"],
      ["Ctrl+S", "Save the project: all plates in one 3MF file"],
      ["Ctrl+E", "Export the G-code"],
      ["Ctrl+Z", "Undo"],
      ["Ctrl+Shift+Z, Ctrl+Y", "Redo"],
      ["Esc", "Close a menu, the search, or this sheet; then clear the measure, then the selection"],
      ["Menu key, Shift+F10", "The menu of the view"],
    ],
  },
  {
    group: "Copy and paste",
    keys: [
      ["Ctrl+C", "Copy the selection: parts, a label, a support area, the changes of the selected layers, a setting value, or the report of a line"],
      ["Ctrl+X", "Cut the selection: a copy, then it goes"],
      ["Ctrl+V", "Paste: parts next to the selected parts, else at the pointer; a label or a support area on the part under the pointer; layer changes on the selected layers; a value into the setting"],
      ["Ctrl+Shift+V", "Paste the copied parts or plate as a new plate"],
      ["Ctrl+D", "Duplicate the selected parts or the selected label"],
    ],
  },
  {
    group: "Plates",
    keys: [
      ["]", "The next plate: make it active, and show it"],
      ["[", "The plate before: make it active, and show it"],
      ["F", "Show the active plate"],
      ["Home", "Show all plates (with one plate: the start view)"],
    ],
  },
  {
    group: "Tools",
    keys: [
      ["V", "Select: a click selects a line or a support; a drag from a line selects layers"],
      ["M", "Move: a drag moves a part, the wheel turns it 15°"],
      ["G", "Grab: take a part and move it as a real object; the wheel lifts it, Alt and a drag turn it (Shift: 15° steps); let go, and it rests on the plate"],
      ["T", "Measure: two clicks measure between two points"],
      ["P", "Paint: paint filaments on a part (Smart select or Brush)"],
      ["E", "Label: click a face of a part to put text or marks on it, in another filament"],
      ["Drag (Label tool)", "Move the label on the surface (with Shift: in its plane)"],
      ["Wheel over a label (Label tool)", "Turn the label 1° (with Shift: 15°)"],
      ["Delete (Label tool)", "Delete the selected label"],
      ["Esc (Label tool)", "Close the card of the label, then the tool"],
      ["S", "Support (S again opens or closes its pane): click points on the part to draw a support area, and drag the points of an area"],
      ["Enter (Support tool)", "Close the area that you draw (also: click its first point)"],
      ["Backspace (Support tool)", "Remove the last point of the area that you draw"],
      ["Delete (Support tool)", "Delete the selected support area"],
      ["Esc (Support tool)", "Stop the area that you draw, then clear the selected area"],
      ["Gaps button", "Show the gaps of the top layer (no key)"],
      ["Ctrl+click, Ctrl+drag, Ctrl+wheel", "Select, move, and turn a part with any tool"],
      ["Tab, Shift+Tab", "Select the next part, or the part before"],
      ["Left, Right, Up, Down (a part)", "Move the selected parts 1 mm (with Shift: 10 mm)"],
      ["R", "Turn: drag a ring of the selected part to turn it about X, Y, or Z"],
      ["Left, Right (Turn tool)", "Turn the selected part on the bed, 15° (with Shift: 5°)"],
      ["Up, Down (Turn tool)", "Tilt the selected part about X, 15° (with Shift: 5°)"],
      ["Page Up, Page Down (Turn tool)", "Tilt the selected part about Y, 15° (with Shift: 5°)"],
      ["D", "Duplicate the selected parts"],
      ["Delete (a selected line)", "Take the line out of the print: an edit, kept across slices (Ctrl+Z undoes it)"],
      ["Delete", "Remove the selected parts, or the selected support"],
      ["Shift+click", "Select the run of the line: one extrusion, from a retraction to the next"],
      ["Ctrl+Shift+click", "Add the part under the pointer to the selection, or take it out"],
      ["Ctrl+click", "Select the part under the pointer"],
      ["Shift (measure, support)", "No snap"],
    ],
  },
  {
    group: "Layers",
    keys: [
      ["Up, K", "The top layer one up (with a selected line: the nearest line one layer up)"],
      ["Down, J", "The top layer one down (with a selected line: the nearest line one layer down)"],
      ["Page Up, Page Down", "10 layers up or down"],
      ["Ctrl+F, Ctrl+B", "A page of layers up or down (5 % of the print)"],
      ["Shift+K, Shift+J", "Select layers: the range grows up or down, and its card opens"],
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
      ["Shift+Left, Shift+Right, Shift+H, Shift+L", "The line before, or the next line"],
    ],
  },
  {
    group: "Search",
    keys: [
      ["Up, Down", "Go through the results"],
      ["Left, Right", "Change the value of the result: a step, or the next choice"],
      ["Space, Enter", "Turn a switch, or run an action"],
      ["V", "The eye of the result: show only the lines of its setting, or all lines again"],
      ["Tab", "Go into the controls of the result"],
      ["Esc", "Leave a control, then close the search"],
    ],
  },
  {
    group: "History",
    keys: [
      ["Up, Down (History list)", "The next step, or the step before"],
      ["Left, Right (timeline)", "The step before, or the next step"],
    ],
  },
  {
    group: "Mouse and touchpad",
    keys: [
      ["Right drag (hold the right button)", "Orbit with a mouse. On a touchpad, click down with two fingers and slide: pan"],
      ["Left drag", "Orbit; in the Select tool, a drag that starts on a line selects layers"],
      ["Middle drag, or Shift and a drag", "Pan"],
      ["Wheel, light two-finger swipe, pinch", "Zoom toward the pointer"],
      ["Double-click on a side of a part", "Turn the view to face that side, and zoom to it"],
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
