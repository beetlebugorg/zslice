// parts.mjs: the simple parts of the docs pictures, as binary STL files.
// Each part is a union of boxes (the slicer joins the shells).
//
// - board.stl: a board of 40 x 4 x 30 mm that stands on its thin edge.
// - shelf.stl: a post with a shelf on top, which needs support.
// - tee.stl: a post of 10 x 10 x 20 mm with a slab of 50 x 10 x 2 mm on
//   top, 20 mm out into the air on each side (sim_anim.mjs).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { writeFile } from "node:fs/promises";
import path from "node:path";

// The 12 triangles of a box, with their normals out.
function box(x0, y0, z0, x1, y1, z1) {
  const p = (i) => [i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0];
  const quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]];
  const tris = [];
  for (const [a, b, c, d] of quads) tris.push([p(a), p(b), p(c)], [p(a), p(c), p(d)]);
  return tris;
}

function stl(tris) {
  const buf = Buffer.alloc(84 + 50 * tris.length);
  buf.writeUInt32LE(tris.length, 80);
  tris.forEach((t, i) => {
    const o = 84 + 50 * i;
    const u = t[1].map((v, k) => v - t[0][k]);
    const w = t[2].map((v, k) => v - t[0][k]);
    const n = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]];
    const l = Math.hypot(...n) || 1;
    n.forEach((v, k) => buf.writeFloatLE(v / l, o + 4 * k));
    t.flat().forEach((v, k) => buf.writeFloatLE(v, o + 12 + 4 * k));
  });
  return buf;
}

export const PARTS = {
  "board.stl": () => box(0, 0, 0, 40, 4, 30),
  "shelf.stl": () => [...box(0, 0, 0, 12, 12, 40), ...box(-20, -4, 40, 50, 16, 43)],
  "tee.stl": () => [...box(0, 0, 0, 10, 10, 20), ...box(-20, 0, 20, 30, 10, 22)],
};

// Writes the parts into dir. Returns { name: file }.
export async function writeParts(dir) {
  const out = {};
  for (const [name, make] of Object.entries(PARTS)) {
    out[name] = path.join(dir, name);
    await writeFile(out[name], stl(make()));
  }
  return out;
}
