// context-menu.js: the entries of the context menu of the preview (a right
// click in the 3D or the 2D view). This list is the one place for them. It
// has the order and the labels of show_menu in linux/src/ui/view3d.c, and
// each entry names its GTK action, so the two lists are easy to compare.
//
// An entry with `missing` is in the GTK menu, and the web app does not
// have it yet: the text says why. The web menu leaves it out.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Sections, in order. `on`: what is under the pointer. "line": any line;
// "part": a line of a part; "support": a support line; "empty": no line
// (the bed or the air); "always": each time.
export const CONTEXT_MENU = [
  {
    on: "always",
    items: [
      { label: "Paste here", accel: "Ctrl+V", gtk: "view3d.paste-here", act: "pasteHere", when: "clip" },
    ],
  },
  {
    on: "support",
    items: [
      { label: "Remove this support", act: "removeSupport" },
      { label: "Remove the support marks here", gtk: "view3d.remove-marks", act: "removeMarks", when: "marks" },
    ],
  },
  {
    on: "line",
    items: [
      { label: "Preview to this layer", accel: "C", gtk: "preview.cut-to-layer", act: "cutToLayer" },
      { label: "Copy for AI", gtk: "view3d.copy-for-ai", act: "copyForAi" },
    ],
  },
  {
    on: "part",
    items: [
      {
        label: "Add support here",
        gtk: "view3d.add-support",
        submenu: [
          { label: "Grid", gtk: "view3d.add-support(0)", act: "addSupport", arg: 0 },
          { label: "Tree", gtk: "view3d.add-support(1)", act: "addSupport", arg: 1 },
          { label: "Bridge (a pad)", gtk: "view3d.add-support(2)", act: "addSupport", arg: 2 },
        ],
      },
      { label: "Block support here", gtk: "view3d.add-support(3)", act: "addSupport", arg: 3 },
      { label: "Remove the support marks here", gtk: "view3d.remove-marks", act: "removeMarks", when: "marks" },
      { label: "Add a drop of plastic here", gtk: "view3d.add-drop", act: "drop" },
    ],
  },
  {
    on: "part",
    items: [
      { label: "New profile from here up", gtk: "view3d.new-profile(1)", missing: "The web app has no layer profiles yet." },
      { label: "New profile from here down", gtk: "view3d.new-profile(-1)", missing: "The web app has no layer profiles yet." },
    ],
  },
  {
    on: "part",
    items: [
      { label: "Copy the part", accel: "Ctrl+C", gtk: "view3d.copy-part", act: "copyPart" },
      { label: "Cut the part", accel: "Ctrl+X", gtk: "view3d.cut-part", act: "cutPart" },
      { label: "Duplicate the part", accel: "Ctrl+D", gtk: "view3d.duplicate-part", act: "duplicatePart" },
    ],
  },
  {
    on: "part",
    items: [
      { label: "Put this side on the bed", gtk: "view3d.put-down", act: "putDown" },
      {
        label: "Placement",
        gtk: "view3d.place",
        submenu: [
          { label: "Smart placement", gtk: "view3d.place(0)", act: "place", arg: 0 },
          { label: "Less support", gtk: "view3d.place(1)", act: "place", arg: 1 },
          { label: "Strong along X of the part", gtk: "view3d.place(10)", act: "place", arg: 10 },
          { label: "Strong along Y of the part", gtk: "view3d.place(11)", act: "place", arg: 11 },
          { label: "Strong along Z of the part", gtk: "view3d.place(12)", act: "place", arg: 12 },
        ],
      },
    ],
  },
  {
    on: "empty",
    items: [
      { label: "Smart placement", gtk: "win.smart-place", act: "plate", arg: "smart" },
      { label: "Arrange the plate", gtk: "win.arrange", act: "plate", arg: "arrange" },
      { label: "Add models…", gtk: "app.open", act: "addModels" },
      { label: "Clear the plate", gtk: "win.clear-plate", act: "plate", arg: "clear" },
      { label: "Remove this plate", gtk: "win.remove-plate", act: "removePlate" },
    ],
  },
  {
    on: "empty",
    items: [
      { label: "Copy the plate", gtk: "view3d.copy-plate", act: "copyPlate" },
      { label: "Duplicate the plate", gtk: "view3d.duplicate-plate", act: "duplicatePlate" },
      { label: "Paste as a new plate", accel: "Ctrl+Shift+V", gtk: "view3d.paste-plate", act: "pastePlate", when: "clipParts" },
    ],
  },
  {
    on: "always",
    items: [
      { label: "Clear all support marks", gtk: "view3d.clear-marks", act: "clearMarks", when: "marks" },
      { label: "Show all layers", accel: "Shift+C", gtk: "preview.all-layers", act: "allLayers", when: "cut" },
      { label: "Test print: the top layer…", gtk: "preview.debug-print(1)", act: "debugPrint", arg: 1 },
      { label: "Test print: the layers shown…", gtk: "preview.debug-print(0)", act: "debugPrint", arg: 0, when: "cut" },
      { label: "Reset the view", gtk: "view3d.reset-view", act: "resetView" },
    ],
  },
];

// The items for menus.js. ctx: { on ("part", "support", or "empty"),
// marks, cut, clip (the clipboard has a copy), clipParts (it has parts
// or a plate), run(act, arg) }.
export function contextItems(ctx) {
  const out = [];
  const make = (e) => {
    if (e.missing) return null;
    if (e.when === "marks" && !ctx.marks) return null;
    if (e.when === "cut" && !ctx.cut) return null;
    if (e.when === "clip" && !ctx.clip) return null;
    if (e.when === "clipParts" && !ctx.clipParts) return null;
    if (e.submenu) return { label: e.label, submenu: e.submenu.map(make).filter(Boolean) };
    return { label: e.label, accel: e.accel, action: () => ctx.run(e.act, e.arg) };
  };
  for (const section of CONTEXT_MENU) {
    const fits = section.on === "always" || section.on === ctx.on || (section.on === "line" && ctx.on !== "empty");
    if (!fits) continue;
    const items = section.items.map(make).filter(Boolean);
    if (items.length === 0) continue;
    if (out.length > 0) out.push({ sep: true });
    out.push(...items);
  }
  return out;
}
