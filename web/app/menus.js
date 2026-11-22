// menus.js: a popup menu under a button, as a GTK menu button opens, and
// a context menu at the pointer, as a GTK popover menu.
//
// items: { title } starts a section, { sep: true } is a line, and
// { label, detail, checked, disabled, action, accel, submenu, tip } is an
// item (detail: a line in small text under the label). An
// item with a submenu (a list of items) shows the submenu in place of the
// menu, with a back row at the top, as a GTK popover menu does.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const layer = () => document.getElementById("menu-layer");

let onClose = null;

export function closeMenu() {
  const l = layer();
  const was = !l.hidden;
  l.hidden = true;
  l.replaceChildren();
  if (was && onClose) {
    const f = onClose;
    onClose = null;
    f();
  }
}

export function menuOpen() {
  return !layer().hidden;
}

function fill(menu, items, back) {
  menu.replaceChildren();
  if (back) {
    const b = document.createElement("button");
    b.className = "back";
    b.setAttribute("role", "menuitem");
    const c = document.createElement("span");
    c.className = "check";
    c.textContent = "‹";
    const t = document.createElement("span");
    t.textContent = back.label;
    b.append(c, t);
    b.onclick = () => fill(menu, back.items, back.back);
    menu.append(b);
    const s = document.createElement("div");
    s.className = "sep";
    menu.append(s);
  }
  for (const it of items) {
    if (it.title !== undefined) {
      const t = document.createElement("div");
      t.className = "section-title";
      t.textContent = it.title;
      menu.append(t);
    } else if (it.sep) {
      const s = document.createElement("div");
      s.className = "sep";
      menu.append(s);
    } else {
      const b = document.createElement("button");
      b.setAttribute("role", "menuitem");
      const c = document.createElement("span");
      c.className = "check";
      c.textContent = it.checked ? "✓" : "";
      const t = document.createElement("span");
      t.className = "label";
      t.textContent = it.label;
      // A dot of a color before the label (a printer of a deck with more
      // than one printer).
      if (/^#[0-9a-f]{6}$/i.test(it.color ?? "")) {
        const dot = document.createElement("span");
        dot.className = "menu-dot";
        dot.style.background = it.color;
        t.prepend(dot);
      }
      // A line under the label in small text (the main points of a quality).
      if (it.detail) {
        const d = document.createElement("span");
        d.className = "menu-detail";
        d.textContent = it.detail;
        t.append(d);
      }
      b.append(c, t);
      if (it.accel || it.submenu) {
        const a = document.createElement("span");
        a.className = "accel";
        a.textContent = it.submenu ? "›" : it.accel;
        b.append(a);
      }
      if (it.tip) b.title = it.tip;
      b.disabled = !!it.disabled;
      b.onclick = () => {
        if (it.submenu) {
          fill(menu, it.submenu, { label: it.label, items, back });
          menu.querySelector("button:not(:disabled)")?.focus();
          return;
        }
        closeMenu();
        it.action?.();
      };
      menu.append(b);
    }
  }
}

// Opens a menu; place(w, h) gives its top left corner.
function open(items, place, closed) {
  const l = layer();
  closeMenu();
  onClose = closed ?? null;
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.setAttribute("role", "menu");
  fill(menu, items, null);
  l.append(menu);
  l.hidden = false;
  const w = menu.offsetWidth;
  const h = menu.offsetHeight;
  let [x, y] = place(w, h);
  x = Math.max(4, Math.min(x, window.innerWidth - w - 4));
  // A long menu keeps its place and takes the height down to the bottom
  // of the window, so that all of it shows. A menu with too little room
  // there moves up.
  const room = window.innerHeight - Math.max(4, y) - 4;
  if (h > room && room >= 240) {
    y = Math.max(4, y);
    menu.style.maxHeight = `${room}px`;
  } else {
    y = Math.max(4, Math.min(y, window.innerHeight - h - 4));
  }
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
  l.onpointerdown = (e) => {
    if (e.target === l) closeMenu();
  };
  l.oncontextmenu = (e) => {
    e.preventDefault();
    if (e.target === l) closeMenu();
  };
  menu.querySelector("button:not(:disabled)")?.focus();
}

// A button of a vertical tool strip: the menu opens at its right, inside
// the view of the strip, so it covers neither the strip, the header, nor
// the bar under the view. Else null.
function besideStrip(anchor, h) {
  const strip = anchor.closest?.('[aria-orientation="vertical"]');
  if (!strip) return null;
  const r = anchor.getBoundingClientRect();
  const host = strip.parentElement ?? strip;
  const v = host.getBoundingClientRect();
  // The bar under the view floats in it (app.js sets --dock-h).
  const dock = parseFloat(getComputedStyle(host).getPropertyValue("--dock-h")) || 0;
  return [r.right + 6, Math.max(v.top + 4, Math.min(r.top, v.bottom - dock - h - 4))];
}

export function openMenu(anchor, items) {
  open(items, (w, h) => {
    const side = besideStrip(anchor, h);
    if (side) return side;
    const r = anchor.getBoundingClientRect();
    let x = r.left;
    if (x + w > window.innerWidth - 4) x = Math.max(4, r.right - w);
    let y = r.bottom + 4;
    if (y + h > window.innerHeight - 4) y = Math.max(4, r.top - h - 4);
    return [x, y];
  });
}

// A popover with `node` under `anchor` (the "why" text of a number).
export function openPopover(anchor, node) {
  const l = layer();
  closeMenu();
  const box = document.createElement("div");
  box.className = "menu popover";
  box.append(node);
  l.append(box);
  l.hidden = false;
  const r = anchor.getBoundingClientRect();
  const w = box.offsetWidth;
  const h = box.offsetHeight;
  let x = Math.max(4, Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 4));
  let y = r.bottom + 4;
  if (y + h > window.innerHeight - 4) y = Math.max(4, r.top - h - 4);
  const side = besideStrip(anchor, h);
  if (side) [x, y] = side;
  box.style.left = `${x}px`;
  box.style.top = `${y}px`;
  l.onpointerdown = (e) => {
    if (e.target === l) closeMenu();
  };
}

// A context menu at the client point (x, y). `closed` runs when it closes.
export function openMenuAt(x, y, items, closed) {
  open(items, () => [x, y], closed);
}

// Escape closes the menu, before the keys of the preview see it.
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !layer().hidden) {
    e.preventDefault();
    e.stopImmediatePropagation();
    closeMenu();
  }
}, true);
