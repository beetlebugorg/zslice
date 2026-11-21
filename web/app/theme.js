// theme.js: the light or dark look of the page. The page follows the
// system (prefers-color-scheme), as the GTK and macOS shells do. The main
// menu can set light or dark in place of the system; this browser keeps
// the choice (localStorage). The colors are tokens in style.css: this
// module sets data-theme on the root element to pick a set.
//
// A query flag ?theme=light or ?theme=dark sets the theme for one page
// load and does not keep it (for tests).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const KEY = "zslice.theme";
const CHOICES = ["system", "light", "dark"];
const media = window.matchMedia?.("(prefers-color-scheme: dark)");
const listeners = new Set();

function stored() {
  const q = new URLSearchParams(location.search).get("theme");
  if (CHOICES.includes(q)) return q;
  try {
    const v = localStorage.getItem(KEY);
    if (CHOICES.includes(v)) return v;
  } catch {
    // No storage (a private window): the page follows the system.
  }
  return "system";
}

let choice = stored();

function apply() {
  const root = document.documentElement;
  if (choice === "system") delete root.dataset.theme;
  else root.dataset.theme = choice;
}

function changed() {
  apply();
  for (const f of listeners) f(isDark());
}

// The choice: "system", "light", or "dark".
export function themeChoice() {
  return choice;
}

// True when the page shows the dark colors.
export function isDark() {
  if (choice === "dark") return true;
  if (choice === "light") return false;
  return !!media?.matches;
}

// Sets the choice and keeps it in this browser.
export function setTheme(c) {
  if (!CHOICES.includes(c) || c === choice) return;
  choice = c;
  try {
    if (c === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, c);
  } catch {
    // No storage: the choice lasts until the page closes.
  }
  changed();
}

// f(dark) runs when the colors change: a new choice, or a change of the
// system while the page follows the system.
export function onThemeChange(f) {
  listeners.add(f);
}

media?.addEventListener?.("change", () => {
  if (choice === "system") changed();
});

apply();
