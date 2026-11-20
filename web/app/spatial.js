// spatial.js: each card remembers where the user put it, and its size.
//
// The user asked for this: "remember where I put it, leave it there, and
// pop it up there the next time I need it". Each kind of card (the line
// card, the range card, the part card, the history card, the search) has
// one place and one size in this browser (localStorage). A card that opens
// goes to its place, unless there it covers the thing that the user
// clicked: a card never covers that (see place.js); then it goes to the
// automatic place for this time. A double click on the head of a card
// forgets its place and its size.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { freeArea } from "./place.js";

const KEY = "zslice.spatial.v1";

function load() {
  try {
    return JSON.parse(localStorage.getItem(KEY)) ?? {};
  } catch {
    return {};
  }
}

function store(all) {
  try {
    localStorage.setItem(KEY, JSON.stringify(all));
  } catch {
    // No storage (a private window): the place lasts until a reload.
  }
}

// The place and the size of a kind: { x, y, w, h } (CSS pixels in the
// host), or {}.
export function saved(kind) {
  return load()[kind] ?? {};
}

export function remember(kind, patch) {
  const all = load();
  all[kind] = { ...all[kind], ...patch };
  store(all);
}

export function forget(kind) {
  const all = load();
  delete all[kind];
  store(all);
}

// Makes `card` resizable (a grip at its lower right corner), with the size
// of its kind. A resize by the user is kept. `reset()`: after a double
// click on `handle`, the place and the size go, and the card places itself
// again.
export function spatial(card, kind, handle = null, reset = null) {
  card.classList.add("spatial");
  const s = saved(kind);
  if (s.w > 0) card.style.width = `${s.w}px`;
  if (s.h > 0) card.style.height = `${s.h}px`;
  // A resize with the grip changes the inline size: keep it at the end of
  // the press.
  card.addEventListener("pointerdown", () => {
    const w0 = card.style.width;
    const h0 = card.style.height;
    window.addEventListener(
      "pointerup",
      () => {
        if (card.style.width !== w0 || card.style.height !== h0) remember(kind, { w: card.offsetWidth, h: card.offsetHeight });
      },
      { once: true },
    );
  });
  if (handle) {
    handle.addEventListener("dblclick", (e) => {
      if (e.target.closest("button, input, select, textarea, a")) return;
      forget(kind);
      card.style.width = "";
      card.style.height = "";
      reset?.();
    });
  }
}

// The kept place of a kind for `card` in `host`, moved inside the free
// area of the view, or null: none, or it covers `box` (x0, y0, x1, y1, the
// thing that the user clicked, in the pixels of the host).
export function savedPlace(kind, card, host, box = null) {
  const s = saved(kind);
  if (!(s.x >= 0 && s.y >= 0)) return null;
  const area = freeArea(host);
  const w = card.offsetWidth;
  const h = card.offsetHeight;
  const x = Math.max(area[0], Math.min(s.x, area[2] - w));
  const y = Math.max(area[1], Math.min(s.y, area[3] - Math.min(h, 80)));
  if (box && x < box[2] && x + w > box[0] && y < box[3] && y + h > box[1]) return null;
  return [x, y];
}
