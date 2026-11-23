// place.js: where a card goes next to the thing that it is about.
//
// A card must never cover the thing that the user clicked, or any part of
// it. placeBeside puts the card in the first space beside the box of that
// thing (on the screen) where it fits whole: to the right, to the left,
// below, or above, with a gap. If no side has the room, it goes to the
// side with the most room, still out of the box where it can. A side that
// also leaves the boxes of `avoid` clear comes first, so that a card does
// not take the clicks of another part.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export const GAP = 16;

// box: the thing on the screen, in CSS pixels of the host (x0, y0, x1, y1).
// area: the free part of the host (x0, y0, x1, y1), with the bars and the
// tool strip left out. w, h: the size of the card. avoid: boxes to keep
// clear if a side can. Returns [left, top].
export function placeBeside(box, area, w, h, avoid = []) {
  const [bx0, by0, bx1, by1] = box;
  const [ax0, ay0, ax1, ay1] = area;
  const midY = (by0 + by1) / 2 - h / 2;
  const midX = (bx0 + bx1) / 2 - w / 2;
  const clampX = (x) => Math.max(ax0, Math.min(ax1 - w, x));
  const clampY = (y) => Math.max(ay0, Math.min(ay1 - h, y));
  const sides = [
    { room: ax1 - (bx1 + GAP), need: w, at: () => [bx1 + GAP, clampY(midY)] },
    { room: bx0 - GAP - ax0, need: w, at: () => [bx0 - GAP - w, clampY(midY)] },
    { room: ay1 - (by1 + GAP), need: h, at: () => [clampX(midX), by1 + GAP] },
    { room: by0 - GAP - ay0, need: h, at: () => [clampX(midX), by0 - GAP - h] },
  ];
  const clear = ([x, y]) => !avoid.some((b) => overlaps([x, y, x + w, y + h], b));
  for (const s of sides) if (s.room >= s.need && clear(s.at())) return s.at();
  // No side is clear as it is: the card goes further out on a side, past
  // a box to avoid.
  const y0 = clampY(midY);
  const x0 = clampX(midX);
  const further = [
    ...avoid.map((b) => [b[2] + GAP, y0]).filter(([x]) => x >= bx1 + GAP && x + w <= ax1),
    ...avoid.map((b) => [b[0] - GAP - w, y0]).filter(([x]) => x + w <= bx0 - GAP && x >= ax0),
    ...avoid.map((b) => [x0, b[3] + GAP]).filter(([, y]) => y >= by1 + GAP && y + h <= ay1),
    ...avoid.map((b) => [x0, b[1] - GAP - h]).filter(([, y]) => y + h <= by0 - GAP && y >= ay0),
  ];
  for (const q of further) if (clear(q)) return q;
  for (const s of sides) if (s.room >= s.need) return s.at();
  // No side has the room: the side with the most, at the edge of the area.
  const best = sides.reduce((a, b) => (b.room / b.need > a.room / a.need ? b : a));
  const [x, y] = best.at();
  return [clampX(x), clampY(y)];
}

// True if two boxes (x0, y0, x1, y1) overlap.
export function overlaps(a, b) {
  return a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1];
}

// The free area of the view: the tool strip at the left, the top bar, the
// bottom bar (--dock-h), and the layer slider at the right.
export function freeArea(host) {
  const r = host.getBoundingClientRect();
  const dock = parseFloat(getComputedStyle(host).getPropertyValue("--dock-h")) || 70;
  return [62, 8, r.width - 60, r.height - dock - 12];
}

// The corners of the free area, in the order of a card that docks:
// top left, top right, bottom left, bottom right.
export const CORNERS = ["tl", "tr", "bl", "br"];

// A card in a corner of the area, away from the box of the thing that the
// user clicked. The card keeps its corner `keep` while that corner stays
// clear of the box, so it does not jump from click to click. Else it goes
// to the first clear corner, or to the corner with the least overlap.
// Returns [left, top, corner, the overlap with the box in px²].
export function placeCorner(box, area, w, h, keep) {
  // A small gap to the tool strip, and room at the right for the layer
  // label of the slider.
  const [ax0, ay0, ax1, ay1] = [area[0] + 8, area[1], area[2] - 40, area[3]];
  const at = (c) => [c[1] === "l" ? ax0 : Math.max(ax0, ax1 - w), c[0] === "t" ? ay0 : Math.max(ay0, ay1 - h)];
  const overlap = (c) => {
    const [x, y] = at(c);
    const ox = Math.min(x + w, box[2] + GAP) - Math.max(x, box[0] - GAP);
    const oy = Math.min(y + h, box[3] + GAP) - Math.max(y, box[1] - GAP);
    return ox > 0 && oy > 0 ? ox * oy : 0;
  };
  const order = keep ? [keep, ...CORNERS.filter((c) => c !== keep)] : CORNERS;
  let best = order[0];
  for (const c of order) {
    if (overlap(c) === 0) return [...at(c), c, 0];
    if (overlap(c) < overlap(best)) best = c;
  }
  return [...at(best), best, overlap(best)];
}
