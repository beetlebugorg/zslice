// spatial.js: the undocked search remembers where the user put it, and
// its size, in this browser (localStorage). A double click on its head
// forgets them. The cards of a selection are in the Inspector (dock.js).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

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
