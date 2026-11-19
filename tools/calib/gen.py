#!/usr/bin/env python3
"""Make the calibration parts: test prints that measure sag and droop.

Each part is made in code (no files from the net). The parts:

- overhang.stl: a comb of fins on a back wall. The underside of each
  fin leans out at one angle from vertical, from 30 to 80 degrees in
  steps of 5. The top of each fin is flat at the same height, and the
  tip of each fin is 2 mm thick. The angle is raised text on the top
  of the fin.
- bridges.stl: six bridges with spans of 10, 20, 30, 40, 60, and 80 mm.
  Each bridge is a deck of 1.6 mm on two piers 8 mm high. The span is
  raised text on the top of the left pier.
- ledges.stl: three posts, each with a slab that sticks out 5, 10, or
  20 mm over air. The slab is 1.6 mm thick. The length is raised text
  on the top of the post.

The text uses digits of seven bars, as on a clock. A bar is a box, so
the digits print well with a 0.5 mm nozzle.

Usage: gen.py OUT_DIR. Writes OUT_DIR/overhang.stl, bridges.stl,
ledges.stl, and features.tsv (the place and the size of each feature,
for predict.py).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import math
import os
import struct
import sys

# The overhang comb.
ANGLES = list(range(30, 85, 5))
FIN_WIDTH = 6.0  # along x
FIN_GAP = 2.0
FIN_REACH = 8.0  # how far the fin sticks out from the back wall (y)
FIN_TIP = 2.0  # the thickness of the fin at its tip
BACK_DEPTH = 4.0  # the back wall (y)

# The bridges.
SPANS = [10, 20, 30, 40, 60, 80]
PIER_X = 6.0
PIER_Y = 8.0
PIER_H = 8.0
DECK = 1.6
BRIDGE_PITCH = 12.0  # along y

# The ledges.
LEDGES = [5, 10, 20]
POST = 8.0
POST_H = 8.0
LEDGE_PITCH = 14.0

# The text: digit size along the line of text and across it, the bar
# width, and the height of the raised text.
DIGIT_W = 3.0
DIGIT_H = 4.6
BAR = 0.9
DIGIT_GAP = 1.0
TEXT_UP = 0.6


def quad(a, b, c, d):
    return [(a, b, c), (a, c, d)]


def box(x0, y0, z0, x1, y1, z1):
    p = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
    f = []
    f += quad(p[0], p[2], p[3], p[1])  # bottom (down)
    f += quad(p[4], p[5], p[7], p[6])  # top
    f += quad(p[0], p[1], p[5], p[4])  # y0
    f += quad(p[2], p[6], p[7], p[3])  # y1
    f += quad(p[0], p[4], p[6], p[2])  # x0
    f += quad(p[1], p[3], p[7], p[5])  # x1
    return f


def prism_x(poly, x0, x1):
    """A prism along x from x0 to x1 of a polygon in (y, z), counter
    clockwise. The polygon must be star shaped from its first point."""
    f = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        f += quad((x0, a[0], a[1]), (x0, b[0], b[1]), (x1, b[0], b[1]), (x1, a[0], a[1]))
    for i in range(1, n - 1):
        a, b, c = poly[0], poly[i], poly[i + 1]
        # The cap at x1 faces +x: (y, z) counter clockwise seen from +x.
        f.append(((x1, a[0], a[1]), (x1, b[0], b[1]), (x1, c[0], c[1])))
        f.append(((x0, a[0], a[1]), (x0, c[0], c[1]), (x0, b[0], b[1])))
    return f


# The bars of each digit: a top, b top right, c bottom right, d bottom,
# e bottom left, f top left, g middle.
SEGMENTS = {
    "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc",
    "5": "afgcd", "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg",
}


def digit_bars(ch):
    """The bars of a digit as boxes (u0, v0, u1, v1) in a cell of
    DIGIT_W by DIGIT_H, with v up. The bars do not overlap."""
    w, h, t = DIGIT_W, DIGIT_H, BAR
    mid = h / 2
    bars = {
        "a": (0, h - t, w, h),
        "d": (0, 0, w, t),
        "g": (0, mid - t / 2, w, mid + t / 2),
        "f": (0, mid + t / 2, t, h - t),
        "b": (w - t, mid + t / 2, w, h - t),
        "e": (0, t, t, mid - t / 2),
        "c": (w - t, t, w, mid - t / 2),
    }
    return [bars[s] for s in SEGMENTS[ch]]


def text(s, cx, cy, z):
    """Raised text on a top at z, centered at (cx, cy). It reads along
    +y, and its up is -x, so it reads from the front of the bed turned a
    quarter turn."""
    f = []
    total = len(s) * DIGIT_W + (len(s) - 1) * DIGIT_GAP
    u0 = -total / 2
    for i, ch in enumerate(s):
        base = u0 + i * (DIGIT_W + DIGIT_GAP)
        for (a, b, c, d) in digit_bars(ch):
            # u along +y, v along -x.
            y0, y1 = cy + base + a, cy + base + c
            x0, x1 = cx + DIGIT_H / 2 - d, cx + DIGIT_H / 2 - b
            f += box(x0, y0, z, x1, y1, z + TEXT_UP)
    return f


def overhang():
    """The comb of fins, and the features: (name, angle, x0, x1, y0,
    y1, z0, z1) of the overhang part of each fin."""
    height = FIN_TIP + FIN_REACH / math.tan(math.radians(ANGLES[0])) + 0.5
    f = []
    feats = []
    x = 0.0
    for k, a in enumerate(ANGLES):
        rise = FIN_REACH / math.tan(math.radians(a))
        zb = height - FIN_TIP - rise
        # The back wall and the fin as one prism. The polygon is star
        # shaped from its first point, the top of the back wall.
        poly = [(-BACK_DEPTH, height), (-BACK_DEPTH, 0), (0, 0), (0, zb), (FIN_REACH, height - FIN_TIP), (FIN_REACH, height)]
        f += prism_x(poly, x, x + FIN_WIDTH)
        f += text(str(a), x + FIN_WIDTH / 2, (FIN_REACH - BACK_DEPTH) / 2, height)
        feats.append(("overhang", a, x, x + FIN_WIDTH, 0.0, FIN_REACH, zb, height))
        x += FIN_WIDTH
        if k + 1 < len(ANGLES):
            f += box(x, -BACK_DEPTH, 0, x + FIN_GAP, 0, height)
            x += FIN_GAP
    return f, feats


def bridges():
    f = []
    feats = []
    for k, span in enumerate(SPANS):
        y = k * BRIDGE_PITCH
        x1 = PIER_X + span
        f += box(0, y, 0, PIER_X, y + PIER_Y, PIER_H)
        f += box(x1, y, 0, x1 + PIER_X, y + PIER_Y, PIER_H)
        f += box(0, y, PIER_H, x1 + PIER_X, y + PIER_Y, PIER_H + DECK)
        f += text(str(span), PIER_X / 2, y + PIER_Y / 2, PIER_H + DECK)
        feats.append(("bridge", span, PIER_X, x1, y, y + PIER_Y, PIER_H, PIER_H + DECK))
    return f, feats


def ledges():
    f = []
    feats = []
    for k, out in enumerate(LEDGES):
        y = k * LEDGE_PITCH
        f += box(0, y, 0, POST, y + POST, POST_H + DECK)
        f += box(POST, y, POST_H, POST + out, y + POST, POST_H + DECK)
        f += text(str(out), POST / 2, y + POST / 2, POST_H + DECK)
        feats.append(("ledge", out, POST, POST + out, y, y + POST, POST_H, POST_H + DECK))
    return f, feats


def write_stl(path, faces):
    with open(path, "wb") as out:
        out.write(b"zslice calibration part".ljust(80, b"\0"))
        out.write(struct.pack("<I", len(faces)))
        for a, b, c in faces:
            u = [b[i] - a[i] for i in range(3)]
            v = [c[i] - a[i] for i in range(3)]
            n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            ln = math.sqrt(sum(x * x for x in n)) or 1.0
            out.write(struct.pack("<3f", *(x / ln for x in n)))
            for p in (a, b, c):
                out.write(struct.pack("<3f", *p))
            out.write(b"\0\0")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen.py OUT_DIR")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rows = []
    for name, make in (("overhang", overhang), ("bridges", bridges), ("ledges", ledges)):
        faces, feats = make()
        write_stl(os.path.join(out, name + ".stl"), faces)
        rows += [(name + ".stl",) + ft for ft in feats]
    with open(os.path.join(out, "features.tsv"), "w") as t:
        t.write("file\tkind\tsize\tx0\tx1\ty0\ty1\tz0\tz1\n")
        for r in rows:
            t.write("\t".join(str(round(v, 3)) if isinstance(v, float) else str(v) for v in r) + "\n")


if __name__ == "__main__":
    main()
