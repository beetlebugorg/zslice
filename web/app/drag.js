// drag.js: a floating card that the user moves with a drag of its head
// (the search, the line card, the part card). A card that the user moved
// keeps its place (`moved`) until it closes; the code that places the
// card next to its object checks that.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Lets `card` (position: absolute in `host`) move with a drag of
// `handle`. A press on a button, an entry, or a list does not move it.
// onMove(x, y): after each move. Returns { moved() }.
export function movable(card, handle, host, onMove = () => {}) {
  let moved = false;
  handle.classList.add("drag-handle");
  handle.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || e.target.closest("button, input, select, textarea, a")) return;
    e.preventDefault();
    const r = card.getBoundingClientRect();
    const h = host.getBoundingClientRect();
    const dx = e.clientX - r.left;
    const dy = e.clientY - r.top;
    handle.setPointerCapture(e.pointerId);
    handle.classList.add("dragging");
    const move = (ev) => {
      const x = Math.max(0, Math.min(h.width - r.width, ev.clientX - h.left - dx));
      const y = Math.max(0, Math.min(h.height - 40, ev.clientY - h.top - dy));
      card.style.left = `${x}px`;
      card.style.top = `${y}px`;
      moved = true;
      onMove(x, y);
    };
    const up = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", up);
      handle.removeEventListener("pointercancel", up);
      handle.classList.remove("dragging");
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", up);
    handle.addEventListener("pointercancel", up);
  });
  return { moved: () => moved };
}
