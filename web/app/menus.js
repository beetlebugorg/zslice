// menus.js: a popup menu under a button, as a GTK menu button opens.
//
// items: { title } starts a section, { sep: true } is a line, and
// { label, checked, disabled, action } is an item.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const layer = () => document.getElementById("menu-layer");

export function closeMenu() {
  const l = layer();
  l.hidden = true;
  l.replaceChildren();
}

export function openMenu(anchor, items) {
  const l = layer();
  closeMenu();
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.setAttribute("role", "menu");
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
      t.textContent = it.label;
      b.append(c, t);
      b.disabled = !!it.disabled;
      b.onclick = () => {
        closeMenu();
        it.action?.();
      };
      menu.append(b);
    }
  }
  l.append(menu);
  l.hidden = false;
  const r = anchor.getBoundingClientRect();
  const w = menu.offsetWidth;
  const h = menu.offsetHeight;
  let x = r.left;
  if (x + w > window.innerWidth - 4) x = Math.max(4, r.right - w);
  let y = r.bottom + 4;
  if (y + h > window.innerHeight - 4) y = Math.max(4, r.top - h - 4);
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
  l.onpointerdown = (e) => {
    if (e.target === l) closeMenu();
  };
  menu.querySelector("button:not(:disabled)")?.focus();
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !layer().hidden) closeMenu();
});
