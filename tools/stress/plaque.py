#!/usr/bin/env python3
"""Make a plaque with raised letters, for the tests of the paint tool and
the smart select (a click on a letter selects the whole letter).

The plaque is a grid of voxels: a base 2 mm thick, and the letters
"ZSLICE" 1 mm high on it, in a block font of 5 x 7 pixels (1.2 mm each).
Each voxel face that has no voxel next to it is two triangles, so the
mesh is closed, and the top of the base is many small flat squares (as
a CAD export of a text often is). The glyphs have no pixels that touch
only at a corner, so each edge of the mesh has two faces. A round button
(a cylinder 8 mm across, 1.5 mm high) stands on the base too, as a
second mesh that overlaps the base.

Usage: plaque.py OUT.stl

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import math
import struct
import sys

GLYPHS = {
    "Z": ["#####", "....#", "...##", "..##.", ".##..", "##...", "#####"],
    "S": ["#####", "#....", "#....", "#####", "....#", "....#", "#####"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
    "C": ["#####", "#....", "#....", "#....", "#....", "#....", "#####"],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
}

PIXEL = 1.2
BASE_H = 2.0
LETTER_H = 1.0
MARGIN = 4  # pixels around the text


def check(glyph):
    for r in range(len(glyph) - 1):
        for c in range(len(glyph[0]) - 1):
            a, b = glyph[r][c] == "#", glyph[r][c + 1] == "#"
            d, e = glyph[r + 1][c] == "#", glyph[r + 1][c + 1] == "#"
            if (a and e and not b and not d) or (b and d and not a and not e):
                raise SystemExit(f"a glyph has pixels that touch at a corner: {glyph}")


def plaque(text):
    cols = len(text) * 6 - 1 + 2 * MARGIN + 10  # room for the button
    rows = 7 + 2 * MARGIN
    # The voxels: (x, y, k), k = 0 the base, 1 the letters.
    full = set()
    for x in range(cols):
        for y in range(rows):
            full.add((x, y, 0))
    for i, ch in enumerate(text):
        g = GLYPHS[ch]
        check(g)
        for r, line in enumerate(g):
            for c, p in enumerate(line):
                if p == "#":
                    full.add((MARGIN + 6 * i + c, MARGIN + 6 - r, 1))
    zs = [0.0, BASE_H, BASE_H + LETTER_H]
    tris = []

    def quad(a, b, c, d):
        tris.append((a, b, c))
        tris.append((a, c, d))

    for (x, y, k) in full:
        x0, x1 = x * PIXEL, (x + 1) * PIXEL
        y0, y1 = y * PIXEL, (y + 1) * PIXEL
        z0, z1 = zs[k], zs[k + 1]
        if (x, y, k - 1) not in full:
            quad((x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0))
        if (x, y, k + 1) not in full:
            quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1))
        if (x - 1, y, k) not in full:
            quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0))
        if (x + 1, y, k) not in full:
            quad((x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1))
        if (x, y - 1, k) not in full:
            quad((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1))
        if (x, y + 1, k) not in full:
            quad((x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0))
    # The button: a cylinder that stands 1.5 mm over the base, with its
    # bottom 0.5 mm in the base.
    cx = (cols - 6) * PIXEL
    cy = rows * PIXEL / 2
    r = 4.0
    n = 48
    zb, zt = BASE_H - 0.5, BASE_H + 1.5
    for i in range(n):
        a0 = 2 * math.pi * i / n
        a1 = 2 * math.pi * (i + 1) / n
        p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
        p1 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
        tris.append(((cx, cy, zb), (p1[0], p1[1], zb), (p0[0], p0[1], zb)))
        tris.append(((cx, cy, zt), (p0[0], p0[1], zt), (p1[0], p1[1], zt)))
        quad((p0[0], p0[1], zb), (p1[0], p1[1], zb), (p1[0], p1[1], zt), (p0[0], p0[1], zt))
    return tris


def write_stl(path, tris):
    with open(path, "wb") as f:
        f.write(b"zslice plaque with raised letters".ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        for t in tris:
            f.write(struct.pack("<3f", 0, 0, 0))
            for v in t:
                f.write(struct.pack("<3f", *v))
            f.write(b"\0\0")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    tris = plaque("ZSLICE")
    write_stl(sys.argv[1], tris)
    print(f"{len(tris)} triangles")
