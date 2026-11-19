#!/usr/bin/env python3
"""Make a corpus of STL files that test the slicer at its edges.

Each shape is made in code (no files from the net), then written in
several turns and scales. The shapes:

- plain solids: a box, a cylinder, a sphere, a torus, stairs;
- walls from 0.1 mm to 1.2 mm thick, and needles with tiny tops;
- overhang ramps from 30 to 85 degrees, bridges from 5 to 80 mm, and a
  cantilever slab;
- a plate with holes from 0.5 mm to 20 mm;
- a tiny part (0.5 mm), and a part larger than the bed;
- many shells, nested shells (a box in a box), and a part off the bed;
- broken meshes: flipped normals, zero-area and duplicate faces, an open
  mesh with a face gone;
- a dense sphere (about 400 000 faces).

Usage: gen.py OUT_DIR [--quick]. Writes OUT_DIR/<shape>__<variant>.stl
and OUT_DIR/index.tsv (file, shape, turn, scale).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import math
import os
import struct
import sys


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


def cylinder(r, h, n=64, cx=0.0, cy=0.0, z0=0.0):
    f = []
    for i in range(n):
        a0 = 2 * math.pi * i / n
        a1 = 2 * math.pi * (i + 1) / n
        p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
        p1 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
        f.append(((cx, cy, z0), (p1[0], p1[1], z0), (p0[0], p0[1], z0)))
        f.append(((cx, cy, z0 + h), (p0[0], p0[1], z0 + h), (p1[0], p1[1], z0 + h)))
        f += quad((p0[0], p0[1], z0), (p1[0], p1[1], z0), (p1[0], p1[1], z0 + h), (p0[0], p0[1], z0 + h))
    return f


def sphere(r, n=48, cz=None):
    cz = r if cz is None else cz
    f = []
    for i in range(n):
        t0 = math.pi * i / n
        t1 = math.pi * (i + 1) / n
        for j in range(2 * n):
            u0 = 2 * math.pi * j / (2 * n)
            u1 = 2 * math.pi * (j + 1) / (2 * n)

            def pt(t, u):
                return (r * math.sin(t) * math.cos(u), r * math.sin(t) * math.sin(u), cz + r * math.cos(t))

            a, b, c, d = pt(t0, u0), pt(t1, u0), pt(t1, u1), pt(t0, u1)
            if i > 0:
                f.append((a, b, d))
            if i < n - 1:
                f.append((b, c, d))
    return f


def torus(R, r, n=64, m=24):
    f = []
    for i in range(n):
        for j in range(m):
            def pt(a, b):
                return ((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r + r * math.sin(b))

            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            b0, b1 = 2 * math.pi * j / m, 2 * math.pi * (j + 1) / m
            f += quad(pt(a0, b0), pt(a1, b0), pt(a1, b1), pt(a0, b1))
    return f


def ramp(angle):
    """A wall that leans out at `angle` degrees from vertical."""
    h = 20.0
    run = h * math.tan(math.radians(angle))
    t = 3.0
    w = 20.0
    # A prism: the profile in x-z is a parallelogram.
    pts = [(0, 0), (t, 0), (t + run, h), (run, h)]
    f = []
    for i in range(4):
        a, b = pts[i], pts[(i + 1) % 4]
        f += quad((a[0], 0, a[1]), (b[0], 0, b[1]), (b[0], w, b[1]), (a[0], w, a[1]))
    f += [((pts[0][0], 0, pts[0][1]), (pts[2][0], 0, pts[2][1]), (pts[1][0], 0, pts[1][1])),
          ((pts[0][0], 0, pts[0][1]), (pts[3][0], 0, pts[3][1]), (pts[2][0], 0, pts[2][1])),
          ((pts[0][0], w, pts[0][1]), (pts[1][0], w, pts[1][1]), (pts[2][0], w, pts[2][1])),
          ((pts[0][0], w, pts[0][1]), (pts[2][0], w, pts[2][1]), (pts[3][0], w, pts[3][1]))]
    return f


def bridge(span):
    return box(0, 0, 0, 5, 10, 10) + box(5 + span, 0, 0, 10 + span, 10, 10) + box(0, 0, 10, 10 + span, 10, 12)


def holes_plate():
    f = box(0, 0, 0, 80, 20, 0.0001)[:0]  # nothing
    # A plate with cylinders standing out for each hole size (the slicer
    # sees thin pins and round walls; holes as rings).
    f = box(0, 0, 0, 90, 25, 3)
    x = 5.0
    for d in (0.5, 1, 2, 3, 5, 8, 12, 20):
        f += cylinder(d / 2 + 0.8, 6, 48, x + d / 2, 12.5, 3)
        x += d + 4
    return f


def stairs():
    f = []
    for k in range(10):
        f += box(k * 4, 0, 0, k * 4 + 4, 20, (k + 1) * 2)
    return f


def needles():
    f = []
    for k in range(8):
        r = 0.2 + 0.3 * k
        f += cylinder(r, 15, 16, k * 6, 0, 0)
    return f


def walls():
    f = []
    for k, t in enumerate((0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.2)):
        f += box(k * 6, 0, 0, k * 6 + t, 30, 15)
    return f


def nested():
    outer = box(0, 0, 0, 30, 30, 30)
    inner = box(5, 5, 5, 25, 25, 25)
    inner = [(a, c, b) for a, b, c in inner]  # a hollow: the inner box faces in
    return outer + inner + box(10, 10, 10, 20, 20, 20)


def many_shells():
    f = []
    for i in range(10):
        for j in range(10):
            f += box(i * 8, j * 8, 0, i * 8 + 5, j * 8 + 5, 3 + (i + j) % 5)
    return f


def flipped():
    return [(a, c, b) for a, b, c in box(0, 0, 0, 20, 20, 20)]


def degenerate():
    f = box(0, 0, 0, 20, 20, 10)
    f += [((0, 0, 0), (0, 0, 0), (1, 1, 1))]  # zero area
    f += f[:4]  # duplicate faces
    f += [((5, 5, 10), (10, 5, 10), (15, 5, 10))]  # a line
    return f


def open_mesh():
    return box(0, 0, 0, 20, 20, 20)[2:]  # the bottom face is gone


SHAPES = {
    "box": lambda: box(0, 0, 0, 20, 20, 20),
    "cylinder": lambda: cylinder(10, 30, 96),
    "sphere": lambda: sphere(15, 48),
    "torus": lambda: torus(15, 5),
    "stairs": stairs,
    "walls": walls,
    "needles": needles,
    "ramp30": lambda: ramp(30),
    "ramp50": lambda: ramp(50),
    "ramp70": lambda: ramp(70),
    "ramp85": lambda: ramp(85),
    "bridge5": lambda: bridge(5),
    "bridge20": lambda: bridge(20),
    "bridge80": lambda: bridge(80),
    "cantilever": lambda: box(0, 0, 0, 10, 10, 20) + box(0, 0, 20, 50, 10, 23),
    "holes": holes_plate,
    "tiny": lambda: box(0, 0, 0, 0.5, 0.5, 0.5),
    "huge": lambda: box(0, 0, 0, 300, 50, 10),
    "nested": nested,
    "many_shells": many_shells,
    "floating": lambda: box(0, 0, 10, 20, 20, 20),
    "flipped": flipped,
    "degenerate": degenerate,
    "open": open_mesh,
    "dense_sphere": lambda: sphere(20, 320),
}

# (name, rx, ry, rz) in degrees; scales.
TURNS = [("t0", 0, 0, 0), ("x45", 45, 0, 0), ("y90", 0, 90, 0), ("xy", 30, 60, 15)]
SCALES = [("s1", 1.0), ("s0.2", 0.2), ("s3", 3.0)]
QUICK = {"turns": TURNS[:2], "scales": SCALES[:1]}


def turn(f, rx, ry, rz):
    def rot(p):
        x, y, z = p
        for ax, deg in ((0, rx), (1, ry), (2, rz)):
            if not deg:
                continue
            c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
            if ax == 0:
                y, z = c * y - s * z, s * y + c * z
            elif ax == 1:
                x, z = c * x + s * z, -s * x + c * z
            else:
                x, y = c * x - s * y, s * x + c * y
        return (x, y, z)

    return [tuple(rot(p) for p in t) for t in f]


def write_stl(path, f, k):
    with open(path, "wb") as out:
        out.write(b"zslice stress corpus".ljust(80, b" "))
        out.write(struct.pack("<I", len(f)))
        for t in f:
            out.write(struct.pack("<3f", 0, 0, 0))
            for p in t:
                out.write(struct.pack("<3f", p[0] * k, p[1] * k, p[2] * k))
            out.write(b"\0\0")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    out = sys.argv[1]
    quick = "--quick" in sys.argv
    os.makedirs(out, exist_ok=True)
    turns = QUICK["turns"] if quick else TURNS
    scales = QUICK["scales"] if quick else SCALES
    rows = []
    for name, make in SHAPES.items():
        base = make()
        for tn, rx, ry, rz in turns:
            f = turn(base, rx, ry, rz) if (rx or ry or rz) else base
            for sn, k in scales:
                # The dense sphere and the huge box: one scale only.
                if name in ("dense_sphere", "huge", "tiny") and sn != "s1":
                    continue
                if name == "dense_sphere" and tn != "t0":
                    continue
                file = f"{name}__{tn}_{sn}.stl"
                write_stl(os.path.join(out, file), f, k)
                rows.append(f"{file}\t{name}\t{tn}\t{sn}")
    with open(os.path.join(out, "index.tsv"), "w") as idx:
        idx.write("file\tshape\tturn\tscale\n")
        idx.write("\n".join(rows) + "\n")
    print(f"{len(rows)} files in {out}")


if __name__ == "__main__":
    main()
