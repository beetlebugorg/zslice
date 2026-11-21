#!/usr/bin/env python3
"""Check the support of a sliced part, and compare the support of zslice,
CuraEngine, and OrcaSlicer.

Usage:
  python3 -I tools/support_check.py check <model.stl> <part.gcode> [--png out.png]
  python3 -I tools/support_check.py parts <out folder>
  python3 -I tools/support_check.py rotate <in.stl> <out.stl> [x90] [y45] ...
  python3 -I tools/support_check.py orca-profiles <OrcaSlicer system folder> <out folder>
  python3 -I tools/support_check.py review <out folder> <parts folder>
      [--zslice NAME=BINARY ...] [--cura] [--orca] [--only TEXT]
      [--reuse NAME,...]

check: The checker. It cuts the mesh at the middle of each layer of the
G-code, and draws the outline of the part and the support lines of the
G-code into a grid of 0.1 mm cells. Then, for each layer i:

- A cell of layer i needs support if a face of the mesh between the z of
  layer i - 1 and the z of layer i is over it, and the face looks down and
  leans more than the angle (default 50 degrees) from vertical. So the
  test uses the mesh, and the overhangs of a slicer do not change it.
- A cell has support if a support line of one of the 3 layers under it is
  at most --span (default 1.5 mm) away. A layer can span 2 * span between
  two support lines.
- An unsupported cell needs support and has none.
- A floating support cell is a support line with no support, part, or bed
  under it within --span: a pad in the air between thin branches.

The output gives the overhang area and the unsupported area (summed over
the layers, mm2), the floating support area, the support volume (mm3, from
the extrusion), and the time estimate of the slicer. The G-code can come
from zslice, CuraEngine, or OrcaSlicer: the checker reads the ;TYPE:
comments of each. The G-code and the mesh line up by the center of the box
of the part. --png writes a picture: the view from the front, from the
side, and from the top. The part is grey, the support blue (interface
cyan), the unsupported overhang red, and the floating support orange.

parts: Write the standard test shapes: an overhang test (fins at 45 to 75
degrees), a long bridge between two posts, a T, a mushroom, a ball, and an
arch.

orca-profiles: Write the OrcaSlicer profiles of the review to
<out folder>/orca: the "MyMarlin 0.4 nozzle" machine, the "0.20mm Standard
@MyMarlin" process, and the "Generic PLA @System" filament, each with its
"inherits" chain resolved, and changed to the settings of the review (a
0.5 mm nozzle, 2.85 mm filament, 0.5 mm lines). The system folder is the
"system" folder in the data folder of OrcaSlicer.

review: Slice each STL file of the parts folder with each slicer (support
everywhere, grid and tree), check each slice, and write the pictures and
an index.html with a table of the numbers. Each --zslice gives a zslice
binary and its name (for example base=../zslice/zig-out/bin/zslice).
--only TEXT slices only the parts with TEXT in the name. --reuse
keeps the G-code of the named slicers from an earlier run, and checks it
again. CuraEngine runs as in compare_cura.py; OrcaSlicer runs with the profiles in
<out folder>/orca (see orca-profiles), with no display.

CuraEngine (AGPL-3.0) and OrcaSlicer (AGPL-3.0) are tools that this script
runs. No code is copied. See docs/references/orcaslicer.md.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import html
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

RES = 0.1  # mm per cell
LINE_WIDTH = 0.5
FILAMENT = 2.85


# ---------------------------------------------------------------- STL

def read_stl(path):
    data = open(path, "rb").read()
    if data[:5] == b"solid" and b"facet" in data[:400]:
        pts = re.findall(rb"vertex\s+(\S+)\s+(\S+)\s+(\S+)", data)
        a = np.array(pts, dtype=np.float64)
        return a.reshape(-1, 3, 3)
    n = struct.unpack("<I", data[80:84])[0]
    rec = np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    a = np.frombuffer(data[84:84 + n * 50], dtype=rec)
    return a["v"].astype(np.float64)


def write_stl(path, tris):
    tris = np.asarray(tris, dtype=np.float64)
    rec = np.zeros(len(tris), dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]))
    nn = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    ln = np.linalg.norm(nn, axis=1, keepdims=True)
    ln[ln == 0] = 1
    rec["n"] = nn / ln
    rec["v"] = tris
    with open(path, "wb") as f:
        f.write(b"zslice support check".ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        f.write(rec.tobytes())


def rotate(tris, axis, deg):
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    m = {"x": [[1, 0, 0], [0, c, -s], [0, s, c]],
         "y": [[c, 0, s], [0, 1, 0], [-s, 0, c]],
         "z": [[c, -s, 0], [s, c, 0], [0, 0, 1]]}[axis]
    return tris @ np.array(m).T


def ear_clip(poly):
    """The triangles of a simple counterclockwise polygon."""
    idx = list(range(len(poly)))
    out = []

    def cross(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    while len(idx) > 3:
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(cross(a, b, poly[j]) >= 0 and cross(b, c, poly[j]) >= 0 and cross(c, a, poly[j]) >= 0
                   for j in idx if j not in (i0, i1, i2)):
                continue
            out.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            raise ValueError("polygon is not simple")
    out.append(tuple(idx))
    return out


def extrude_xz(poly, y0, y1):
    """A prism from a polygon in the XZ plane, from y0 to y1."""
    a = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
            for i in range(len(poly)))
    if a < 0:
        poly = poly[::-1]
    tris = []
    for i, j, k in ear_clip(poly):
        p, q, r = poly[i], poly[j], poly[k]
        tris.append([[p[0], y0, p[1]], [q[0], y0, q[1]], [r[0], y0, r[1]]])
        tris.append([[p[0], y1, p[1]], [r[0], y1, r[1]], [q[0], y1, q[1]]])
    for i in range(len(poly)):
        p, q = poly[i], poly[(i + 1) % len(poly)]
        tris.append([[p[0], y0, p[1]], [p[0], y1, p[1]], [q[0], y1, q[1]]])
        tris.append([[p[0], y0, p[1]], [q[0], y1, q[1]], [q[0], y0, q[1]]])
    return np.array(tris, dtype=np.float64)


def revolve(profile, seg=64):
    """A solid of revolution around Z. The profile is a list of (r, z)
    points that starts and ends on the axis."""
    tris = []
    for k in range(seg):
        t0 = 2 * math.pi * k / seg
        t1 = 2 * math.pi * ((k + 1) % seg) / seg
        for (r0, z0), (r1, z1) in zip(profile, profile[1:]):
            a = [r0 * math.cos(t0), r0 * math.sin(t0), z0]
            b = [r0 * math.cos(t1), r0 * math.sin(t1), z0]
            c = [r1 * math.cos(t1), r1 * math.sin(t1), z1]
            d = [r1 * math.cos(t0), r1 * math.sin(t0), z1]
            if r0 > 0:
                tris.append([a, b, c])
            if r1 > 0:
                tris.append([a, c, d])
    return np.array(tris, dtype=np.float64)


def standard_parts():
    parts = {}
    fins = [extrude_xz([(0, 0), (110, 0), (110, 2), (0, 2)], 0, 10)]
    # The fins start on the bed, inside the plate, so that no face of a fin
    # is inside the plate and faces down.
    for k, ang in enumerate([45, 55, 60, 65, 70, 75]):
        x = 2 + k * 18
        dx = min(12 * math.tan(math.radians(ang)), 12)
        h = dx / math.tan(math.radians(ang))
        fins.append(extrude_xz([(x, 0), (x + 4, 0), (x + 4, 2), (x + 4 + dx, 2 + h), (x, 2 + h)], 1, 9))
    parts["overhang-fins"] = np.concatenate(fins)
    parts["long-bridge"] = extrude_xz([(0, 0), (10, 0), (10, 20), (70, 20), (70, 0), (80, 0), (80, 24), (0, 24)], 0, 10)
    parts["t-shape"] = extrude_xz([(30, 0), (40, 0), (40, 25), (70, 25), (70, 30), (0, 30), (0, 25), (30, 25)], 0, 10)
    parts["mushroom"] = revolve([(0, 0), (5, 0), (5, 20), (20, 20), (20, 25), (0, 25)])
    ball = [(0, 0)] + [(15 * math.cos(-math.pi / 2 + math.pi * i / 32), 15 + 15 * math.sin(-math.pi / 2 + math.pi * i / 32))
                       for i in range(1, 32)] + [(0, 30)]
    parts["ball"] = revolve(ball)
    arch = [(0, 0), (10, 0)] + [(30 + 20 * math.cos(math.pi - math.pi * i / 32), 20 * math.sin(math.pi - math.pi * i / 32))
                                for i in range(1, 32)] + [(50, 0), (60, 0), (60, 30), (0, 30)]
    parts["arch"] = extrude_xz(arch, 0, 10)
    return parts


# ---------------------------------------------------------------- G-code

def feature_class(name):
    """0 part, 1 support, 2 support interface, 3 other (skirt, brim)."""
    n = name.lower()
    if "support" in n:
        return 2 if "interface" in n or "roof" in n else 1
    if any(k in n for k in ("skirt", "brim", "custom", "prime", "wipe", "cooling")):
        return 3
    return 0


def read_gcode(path):
    """The extrusions of a G-code file: a dict of z -> list of runs. A run
    is (class, [(x, y), ...]). Also the support filament (mm of filament)
    and the time estimate (s)."""
    layers = {}
    x = y = z = 0.0
    e = 0.0
    rel = False
    cls = 3  # no part before the first ;TYPE: (the start G-code)
    run = None
    sup_e = 0.0
    tot_e = 0.0
    est = None
    for line in open(path, errors="replace"):
        if line.startswith(";"):
            if line.startswith(";TYPE:"):
                cls = feature_class(line[6:].strip())
                run = None
            elif line.startswith(";TIME:") and est is None:
                est = float(line[6:])
            elif line.startswith(";Estimated time:"):
                est = float(line.split(":")[1].strip().rstrip("s"))
            elif "estimated printing time (normal mode)" in line and est is None:
                t = line.split("=")[1]
                est = sum(int(v) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[u] for v, u in re.findall(r"(\d+)([dhms])", t))
            continue
        code = line.split(";", 1)[0].split()
        if not code:
            continue
        g = code[0]
        if g == "M82":
            rel = False
        elif g == "M83":
            rel = True
        elif g == "G92":
            for w in code[1:]:
                if w[0] == "E" and re.fullmatch(r"[-+]?[0-9.]+", w[1:]):
                    e = float(w[1:])
        elif g in ("G0", "G1", "G2", "G3"):
            nx, ny, nz, ne = x, y, z, None
            for w in code[1:]:
                c = w[0]
                if not re.fullmatch(r"[-+]?[0-9.]+", w[1:]):
                    continue
                if c == "X":
                    nx = float(w[1:])
                elif c == "Y":
                    ny = float(w[1:])
                elif c == "Z":
                    nz = float(w[1:])
                elif c == "E":
                    ne = float(w[1:])
            de = 0.0
            if ne is not None:
                de = ne if rel else ne - e
                e = e + ne if rel else ne
            moved = nx != x or ny != y
            if de > 0 and moved and g in ("G0", "G1"):
                tot_e += de
                if cls in (1, 2):
                    sup_e += de
                key = round(nz, 3)
                if run is None or run[2] != key or run[0] != cls or run[1][-1] != (x, y):
                    run = [cls, [(x, y)], key]
                    layers.setdefault(key, []).append(run)
                run[1].append((nx, ny))
            else:
                run = None
            x, y, z = nx, ny, nz
    area = math.pi * FILAMENT * FILAMENT / 4
    return layers, sup_e * area, tot_e * area, est


# ---------------------------------------------------------------- raster

def section(tris, z, x0, y0, nx, ny):
    """The cells inside the mesh cut at z (even-odd rule)."""
    zs = tris[:, :, 2]
    hit = (zs.min(1) < z) & (zs.max(1) > z)
    t = tris[hit]
    grid = np.zeros((ny, nx + 1), dtype=np.int8)
    if len(t) == 0:
        return grid[:, :nx].astype(bool)
    pts = []
    for a, b in ((0, 1), (1, 2), (2, 0)):
        za, zb = t[:, a, 2], t[:, b, 2]
        cross = (za < z) != (zb < z)
        s = (z - za) / np.where(zb == za, 1, zb - za)
        p = t[:, a, :2] + (t[:, b, :2] - t[:, a, :2]) * s[:, None]
        pts.append((cross, p))
    # Each triangle crosses the plane on two edges.
    m = np.stack([c for c, _ in pts], 1)
    ps = np.stack([p for _, p in pts], 1)
    order = np.argsort(~m, axis=1, kind="stable")[:, :2]
    p0 = ps[np.arange(len(t)), order[:, 0]]
    p1 = ps[np.arange(len(t)), order[:, 1]]
    ya = (p0[:, 1] - y0) / RES - 0.5
    yb = (p1[:, 1] - y0) / RES - 0.5
    lo = np.ceil(np.minimum(ya, yb)).astype(np.int64)
    hi = np.ceil(np.maximum(ya, yb)).astype(np.int64)  # exclusive
    lo = np.clip(lo, 0, ny)
    hi = np.clip(hi, 0, ny)
    cnt = hi - lo
    keep = cnt > 0
    if not keep.any():
        return grid[:, :nx].astype(bool)
    lo, cnt = lo[keep], cnt[keep]
    xa, xb = (p0[keep, 0] - x0) / RES - 0.5, (p1[keep, 0] - x0) / RES - 0.5
    ya, yb = ya[keep], yb[keep]
    seg = np.repeat(np.arange(len(lo)), cnt)
    rows = np.repeat(lo, cnt) + (np.arange(cnt.sum()) - np.repeat(np.cumsum(cnt) - cnt, cnt))
    f = (rows - ya[seg]) / np.where(yb[seg] == ya[seg], 1, yb[seg] - ya[seg])
    xc = xa[seg] + (xb[seg] - xa[seg]) * f
    cols = np.clip(np.ceil(xc).astype(np.int64), 0, nx)
    np.add.at(grid, (rows, cols), 1)
    inside = (np.cumsum(grid, axis=1) & 1).astype(bool)
    return inside[:, :nx]


class DownFaces:
    """The faces of the mesh that face down and lean more than the support
    angle from vertical (the normal is less than 90 - angle from straight
    down). The faces on the bed do not count."""

    def __init__(self, tris, angle):
        n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
        ln = np.linalg.norm(n, axis=1)
        ok = ln > 0
        nz = np.where(ok, n[:, 2] / np.where(ok, ln, 1), 0)
        keep = (-nz > math.sin(math.radians(angle)) + 1e-6) & (tris[:, :, 2].max(1) > 1e-3)
        self.t = tris[keep]
        self.zlo = self.t[:, :, 2].min(1)
        self.zhi = self.t[:, :, 2].max(1)

    def layer(self, z0, z1, x0, y0, nx, ny):
        """The cells under the parts of the faces from z0 to z1."""
        img = Image.new("1", (nx, ny), 0)
        d = ImageDraw.Draw(img)
        sel = np.where((self.zhi >= z0) & (self.zlo < z1))[0]
        for k in sel:
            poly = clip_slab(self.t[k], z0, z1)
            if len(poly) < 3:
                continue
            q = [((p[0] - x0) / RES - 0.5, (p[1] - y0) / RES - 0.5) for p in poly]
            d.polygon(q, fill=1, outline=1)
        return np.array(img, dtype=bool)


def clip_slab(tri, z0, z1):
    """The part of a triangle with z0 <= z < z1, as a polygon."""
    poly = [tuple(p) for p in tri]
    for lim, keep_above in ((z0, True), (z1, False)):
        out = []
        for i in range(len(poly)):
            a, b = poly[i], poly[(i + 1) % len(poly)]
            ina = a[2] >= lim if keep_above else a[2] <= lim
            inb = b[2] >= lim if keep_above else b[2] <= lim
            if ina:
                out.append(a)
            if ina != inb:
                t = (lim - a[2]) / (b[2] - a[2])
                out.append(tuple(a[j] + (b[j] - a[j]) * t for j in range(3)))
        poly = out
        if not poly:
            break
    return poly


def dilate(m, steps):
    """Grows a mask by `steps` cells (an octagon)."""
    out = m.copy()
    for k in range(steps):
        a = out.copy()
        a[1:, :] |= out[:-1, :]
        a[:-1, :] |= out[1:, :]
        a[:, 1:] |= out[:, :-1]
        a[:, :-1] |= out[:, 1:]
        if k % 2 == 1:
            a[1:, 1:] |= out[:-1, :-1]
            a[:-1, :-1] |= out[1:, 1:]
            a[1:, :-1] |= out[:-1, 1:]
            a[:-1, 1:] |= out[1:, :-1]
        out = a
    return out


def draw_runs(runs, classes, width, x0, y0, nx, ny, dx, dy):
    img = Image.new("1", (nx, ny), 0)
    d = ImageDraw.Draw(img)
    wpx = max(1, int(round(width / RES)))
    r = wpx / 2
    for cls, pts, _ in runs:
        if cls not in classes:
            continue
        q = [((px + dx - x0) / RES - 0.5, (py + dy - y0) / RES - 0.5) for px, py in pts]
        if len(q) > 1:
            d.line(q, fill=1, width=wpx, joint="curve")
        if wpx > 2:
            for px, py in (q[0], q[-1]):
                d.ellipse([px - r, py - r, px + r, py + r], fill=1)
    return np.array(img, dtype=bool)


# ---------------------------------------------------------------- check

def check(stl, gcode, angle=50.0, span=1.5, png=None, title=""):
    tris = read_stl(stl)
    tris[:, :, 2] -= tris[:, :, 2].min()
    layers, sup_vol, tot_vol, est = read_gcode(gcode)
    zs = sorted(k for k, runs in layers.items() if any(r[0] != 3 for r in runs))
    # The center of the part in the G-code and in the mesh.
    allp = np.array([p for z in zs for r in layers[z] if r[0] == 0 for p in r[1]])
    if len(allp) == 0:
        raise ValueError("no part in the G-code")
    flat = tris.reshape(-1, 3)
    mlo, mhi = flat[:, :2].min(0), flat[:, :2].max(0)
    glo, ghi = allp.min(0), allp.max(0)
    dx, dy = (mlo + mhi) / 2 - (glo + ghi) / 2
    margin = 25.0
    x0, y0 = mlo[0] - margin, mlo[1] - margin
    nx = int((mhi[0] - mlo[0] + 2 * margin) / RES) + 1
    ny = int((mhi[1] - mlo[1] + 2 * margin) / RES) + 1
    down = DownFaces(tris, angle)
    sp = int(round(span / RES))

    prev_m = []  # the part of the 3 layers below
    prev_sr = []  # the supported region of the 3 layers below
    prev_z = 0.0
    need_total = 0.0
    unsup_total = 0.0
    float_total = 0.0
    sup_total = 0.0
    per_layer = []
    rows = []  # for the pictures: (height in cells, front, side, top contributions)
    front = []
    side = []
    top_sup = np.zeros((ny, nx), dtype=np.float32)
    top_bad = np.zeros((ny, nx), dtype=bool)
    top_part = np.zeros((ny, nx), dtype=bool)
    cell = RES * RES
    for i, z in enumerate(zs):
        h = z - prev_z
        # A small shift keeps the cut off the vertices of flat faces.
        m = section(tris, z - h / 2 + 1.37e-4, x0, y0, nx, ny)
        runs = layers[z]
        s = draw_runs(runs, (1, 2), LINE_WIDTH, x0, y0, nx, ny, dx, dy)
        si = draw_runs(runs, (2,), LINE_WIDTH, x0, y0, nx, ny, dx, dy)
        sr = draw_runs(runs, (1, 2), LINE_WIDTH + 2 * span, x0, y0, nx, ny, dx, dy)
        need = np.zeros_like(m)
        bad = np.zeros_like(m)
        floating = np.zeros_like(m)
        if i > 0:
            need = down.layer(prev_z, z, x0, y0, nx, ny)
            have = np.zeros_like(m)
            for x in prev_sr:
                have |= x
            bad = need & ~have
            base = np.zeros_like(m)
            for x in prev_m:
                base |= x
            floating = s & ~prev_sr[-1] & ~base
        need_total += need.sum() * cell
        unsup_total += bad.sum() * cell
        float_total += floating.sum() * cell
        sup_total += s.sum() * cell * h
        per_layer.append((z, need.sum() * cell, bad.sum() * cell, floating.sum() * cell))
        prev_m = (prev_m + [m])[-3:]
        prev_sr = (prev_sr + [sr])[-3:]
        prev_z = z
        if png:
            # Front view (look along +y): the nearest cell of each column.
            cat = np.zeros((ny, nx), dtype=np.int8)
            cat[m] = 1
            cat[s] = 2
            cat[si] = 3
            cat[floating] = 5
            cat[bad] = 4
            front.append((h, view(cat, 0)))
            side.append((h, view(cat, 1)))
            top_sup[s] = z
            top_bad |= bad
            top_part |= m
    res = {
        "layers": len(zs),
        "need_mm2": round(need_total, 1),
        "unsupported_mm2": round(unsup_total, 1),
        "unsupported_pct": round(100 * unsup_total / need_total, 1) if need_total > 0 else 0.0,
        "floating_mm2": round(float_total, 1),
        "support_mm3": round(sup_vol, 1),
        "total_mm3": round(tot_vol, 1),
        "time_s": est,
        "worst_layers": sorted(((round(b, 1), round(z, 2)) for z, _, b, _ in per_layer), reverse=True)[:5],
    }
    if png:
        picture(png, front, side, top_sup, top_bad, top_part, title, res)
    return res


COLORS = np.array([[255, 255, 255], [150, 150, 150], [40, 90, 220], [0, 190, 210], [230, 20, 20], [255, 150, 0]], dtype=np.float32)


def view(cat, axis):
    """The nearest non-empty cell along an axis (0: y, from the front;
    1: x, from the right) and its depth (0 to 1)."""
    occ = cat > 0
    if axis == 0:
        idx = occ.argmax(axis=0)
        any_ = occ.any(axis=0)
        c = cat[idx, np.arange(cat.shape[1])]
        depth = idx / cat.shape[0]
        # A red or orange cell shows through.
        bad = (cat == 4).any(axis=0)
        flt = (cat == 5).any(axis=0)
    else:
        rev = occ[:, ::-1]
        idx = rev.argmax(axis=1)
        any_ = occ.any(axis=1)
        c = cat[np.arange(cat.shape[0]), cat.shape[1] - 1 - idx]
        depth = idx / cat.shape[1]
        bad = (cat == 4).any(axis=1)
        flt = (cat == 5).any(axis=1)
    c = np.where(any_, c, 0)
    c = np.where(flt, 5, c)
    c = np.where(bad, 4, c)
    return c.astype(np.int8), depth.astype(np.float32)


def shade(cats, depths):
    rgb = COLORS[cats]
    k = 1.0 - 0.55 * depths
    lit = (cats == 1) | (cats == 2) | (cats == 3)
    rgb[lit] *= k[lit][:, None]
    return rgb


def stack(rowsv, scale):
    """Rows of a view, one per layer, each as tall as its layer, bottom up."""
    out_c = []
    out_d = []
    for h, (c, d) in rowsv:
        n = max(1, int(round(h / RES)))
        out_c += [c] * n
        out_d += [d] * n
    if not out_c:
        return np.zeros((1, 1, 3), dtype=np.uint8)
    c = np.array(out_c[::-1])
    d = np.array(out_d[::-1])
    rgb = shade(c, d)
    return rgb[::scale, ::scale].clip(0, 255).astype(np.uint8)


def crop(img):
    """The box of the non-white cells, with a 5 px border."""
    nz = np.where((img < 250).any(axis=2))
    if len(nz[0]) == 0:
        return img
    a, b = max(0, nz[0].min() - 5), nz[0].max() + 6
    c, d = max(0, nz[1].min() - 5), nz[1].max() + 6
    return img[a:b, c:d]


def picture(path, front, side, top_sup, top_bad, top_part, title, res):
    # 0.2 mm for each pixel; a small part gets 0.1 mm.
    scale = 2 if top_sup.shape[1] > 1200 else 1
    f = crop(stack(front, scale))
    s = crop(stack(side, scale))
    # Top view: the part grey; support by height (light to dark blue);
    # unsupported cells red.
    zmax = max(top_sup.max(), 1e-6)
    rgb = np.full(top_sup.shape + (3,), 255, dtype=np.float32)
    rgb[top_part] = [200, 200, 200]
    has = top_sup > 0
    t = (top_sup / zmax)[has][:, None]
    rgb[has] = np.array([170, 200, 255]) * (1 - t) + np.array([20, 50, 170]) * t
    rgb[top_bad] = [230, 20, 20]
    tp = crop(rgb[::-1][::scale, ::scale].clip(0, 255).astype(np.uint8))
    pad = 10
    hgt = max(f.shape[0], s.shape[0], tp.shape[0]) + 30
    wid = f.shape[1] + s.shape[1] + tp.shape[1] + 4 * pad
    canvas = Image.new("RGB", (wid, hgt), (255, 255, 255))
    xo = pad
    for im in (f, s, tp):
        canvas.paste(Image.fromarray(im), (xo, 25))
        xo += im.shape[1] + pad
    d = ImageDraw.Draw(canvas)
    d.text((pad, 5), "%s  unsupported %.0f mm2 (%.1f %%)  floating %.0f mm2  support %.0f mm3" % (
        title, res["unsupported_mm2"], res["unsupported_pct"], res["floating_mm2"], res["support_mm3"]), fill=(0, 0, 0))
    canvas.save(path)


# ---------------------------------------------------------------- slicers

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def zslice_slice(binary, stl, out, style, work):
    machine = os.path.join(work, "zslice-profiles", "machine", "lulzbot-taz-workhorse-se.toml")
    if not os.path.exists(machine):
        import compare_cura
        subprocess.run([binary, "import", "cura", compare_cura.TAZ_STACK, "-o", os.path.join(work, "zslice-profiles")],
                       check=True, capture_output=True)
    cmd = [binary, "slice", stl, "-m", machine]
    for kv in ["project.layer_height=0.2", "project.first_layer_height=0.3", "project.wall_count=2",
               "project.infill_density=0.2", "project.infill_pattern=grid", "project.support=everywhere",
               "project.support_style=" + style, "project.support_angle=50", "project.skirt_loops=1",
               "project.brim_width=0", "project.placement=center", "machine.bed_size_x=400", "machine.bed_size_y=400",
               "machine.max_height=400"]:
        cmd += ["-s", kv]
    cmd += ["-o", out]
    t = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.time() - t
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-500:])
    m = re.search(r"sliced in (\d+) ms", p.stderr + p.stdout)
    return int(m.group(1)) / 1000 if m else dt


CURA_SUPPORT = [
    "support_enable=true", "support_type=everywhere", "support_angle=50",
    "support_line_width=0.5", "support_interface_line_width=0.5", "support_roof_line_width=0.5",
    "support_bottom_line_width=0.5", "support_z_distance=0.2", "support_top_distance=0.2",
    "support_bottom_distance=0.2", "support_xy_distance=0.6", "support_xy_distance_overhang=0.25",
    "support_interface_enable=true", "support_roof_enable=true", "support_bottom_enable=false",
    "support_interface_height=0.4", "support_roof_height=0.4", "support_interface_density=70",
    "support_roof_density=70", "support_roof_line_distance=0.714", "support_interface_pattern=lines",
    "support_roof_pattern=lines", "support_infill_sparse_thickness=0.2", "support_wall_thickness=0.5",
    "support_brim_enable=false", "minimum_interface_area=1", "minimum_roof_area=1",
    "support_extruder_nr=0", "support_infill_extruder_nr=0", "support_extruder_nr_layer_0=0",
    "support_interface_extruder_nr=0", "support_roof_extruder_nr=0", "support_bottom_extruder_nr=0",
]
CURA_NORMAL = ["support_structure=normal", "support_pattern=zigzag", "support_infill_rate=15",
               "support_line_distance=3.333", "support_initial_layer_line_distance=3.333",
               "support_offset=0.9", "support_wall_count=0", "support_bottom_stair_step_height=0.3"]
CURA_TREE = ["support_structure=tree", "support_infill_rate=0", "support_line_distance=0",
             "support_initial_layer_line_distance=0", "support_offset=0", "support_wall_count=1",
             "support_tree_angle=50", "support_tree_angle_slow=33.3", "support_tree_tip_diameter=1.0",
             "support_tree_top_rate=30", "support_tree_rest_preference=graceful"]


def cura_slice(stl, out, style, work):
    import compare_cura
    defs = os.path.join(work, "cura-defs")
    if not os.path.exists(defs):
        os.makedirs(defs)
        for name in (compare_cura.TAZ_MACHINE, compare_cura.TAZ_MACHINE + "_extruder"):
            shutil.copy(os.path.join(compare_cura.TAZ_DEFS, name + ".def.json"), defs)
    sets = [kv for kv in compare_cura.CURA_SETTINGS if not kv.startswith(("machine_width", "machine_depth", "machine_height"))]
    sets += ["machine_width=400", "machine_depth=400", "machine_height=400"]
    sets = [kv for kv in sets if not kv.startswith("support_enable")]
    sets += CURA_SUPPORT + (CURA_TREE if style == "tree" else CURA_NORMAL)
    # CuraEngine on the command line stops at a setting with no value. Such
    # a setting gets the default value of fdmprinter.def.json.
    for _ in range(30):
        args = []
        for kv in sets:
            args += ["-s", kv]
        cmd = [compare_cura.CURA_LOADER, compare_cura.CURA_ENGINE, "slice", "-m1", "-j",
               os.path.join(defs, compare_cura.TAZ_MACHINE + ".def.json")] + args + ["-e0"] + args + ["-l", stl, "-o", out]
        env = dict(os.environ, LD_LIBRARY_PATH=compare_cura.CURA_DIR,
                   CURA_ENGINE_SEARCH_PATH=":".join([defs, compare_cura.CURA_DEFS, compare_cura.CURA_EXTRUDERS]))
        t = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        dt = time.time() - t
        text = p.stdout + p.stderr
        m = re.search(r"no value given: (\w+)", text)
        if m:
            sets.append("%s=%s" % (m.group(1), cura_default(m.group(1))))
            continue
        if p.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) == 0:
            bad = [l for l in text.splitlines() if "[error]" in l or "[critical]" in l]
            raise RuntimeError(" | ".join(bad)[-500:] or "CuraEngine failed")
        return dt
    raise RuntimeError("CuraEngine: too many settings with no value")


_CURA_DEFAULTS = None


def cura_default(name):
    global _CURA_DEFAULTS
    if _CURA_DEFAULTS is None:
        import compare_cura
        _CURA_DEFAULTS = {}

        def walk(node):
            for k, v in node.items():
                if isinstance(v, dict):
                    if "default_value" in v:
                        _CURA_DEFAULTS[k] = v["default_value"]
                    walk(v.get("children", {}))
        walk(json.load(open(os.path.join(compare_cura.CURA_DEFS, "fdmprinter.def.json")))["settings"])
    v = _CURA_DEFAULTS[name]
    if isinstance(v, bool):
        return "true" if v else "false"
    return json.dumps(v) if isinstance(v, list) else str(v)


def orca_slice(stl, out, style, work):
    conf = os.path.join(work, "orca")
    proc = json.load(open(os.path.join(conf, "process.json")))
    proc.update({
        "enable_support": "1", "support_type": "tree(auto)" if style == "tree" else "normal(auto)",
        "support_style": "tree_organic" if style == "tree" else "default",
        "support_threshold_angle": "40", "support_top_z_distance": "0.2", "support_bottom_z_distance": "0.2",
        "support_object_xy_distance": "0.6", "support_interface_top_layers": "2",
        "support_interface_bottom_layers": "0", "independent_support_layer_height": "0", "support_interface_spacing": "0.21",
        "support_base_pattern_spacing": "2.83", "support_line_width": "0.5", "support_on_build_plate_only": "0",
    })
    p_path = os.path.join(conf, "process-%s.json" % style)
    json.dump(proc, open(p_path, "w"))
    odir = out + ".d"
    os.makedirs(odir, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "DISPLAY")}
    cmd = ["orca-slicer", "--datadir", os.path.join(conf, "data"),
           "--load-settings", os.path.join(conf, "machine.json") + ";" + p_path,
           "--load-filaments", os.path.join(conf, "filament.json"),
           "--arrange", "1", "--orient", "0", "--slice", "0", "--outputdir", odir, stl]
    t = time.time()
    subprocess.run(cmd, capture_output=True, text=True, env=env)
    dt = time.time() - t
    g = os.path.join(odir, "plate_1.gcode")
    if not os.path.exists(g):
        raise RuntimeError("orca: no G-code")
    shutil.move(g, out)
    shutil.rmtree(odir, ignore_errors=True)
    return dt


def orca_profiles(system, out):
    import glob
    idx = {}
    for path in glob.glob(os.path.join(system, "**", "*.json"), recursive=True):
        try:
            d = json.load(open(path))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and "name" in d:
            idx[(d.get("type"), d["name"])] = d

    def flat(kind, name):
        d = idx[(kind, name)]
        base = flat(kind, d["inherits"]) if d.get("inherits") else {}
        base.update(d)
        return base
    conf = os.path.join(out, "orca")
    os.makedirs(os.path.join(conf, "data"), exist_ok=True)
    for kind, name, fn in (("machine", "MyMarlin 0.4 nozzle", "machine"), ("process", "0.20mm Standard @MyMarlin", "process"),
                           ("filament", "Generic PLA @System", "filament")):
        d = flat(kind, name)
        for k in ("inherits", "setting_id", "instantiation"):
            d.pop(k, None)
        d["from"] = "User"
        d["name"] = "support review " + fn
        if fn == "machine":
            d.update({"nozzle_diameter": ["0.5"], "printable_area": ["0x0", "300x0", "300x300", "0x300"],
                      "printable_height": "300", "machine_start_gcode": "G90\nM83\nG92 E0", "machine_end_gcode": "M84"})
        elif fn == "process":
            d.update({k: "0.5" for k in ("line_width", "outer_wall_line_width", "inner_wall_line_width",
                                         "sparse_infill_line_width", "internal_solid_infill_line_width",
                                         "top_surface_line_width", "initial_layer_line_width", "support_line_width")})
            d.update({"layer_height": "0.2", "initial_layer_print_height": "0.3", "wall_loops": "2",
                      "sparse_infill_density": "20%", "sparse_infill_pattern": "grid", "skirt_loops": "1",
                      "brim_type": "no_brim"})
        else:
            d["filament_diameter"] = ["2.85"]
        json.dump(d, open(os.path.join(conf, fn + ".json"), "w"), indent=1)


def review(args):
    out, parts = os.path.abspath(args[0]), os.path.abspath(args[1])
    zs = []
    cura = orca = False
    only = None
    reuse = set()
    rest = args[2:]
    i = 0
    while i < len(rest):
        if rest[i] == "--zslice":
            name, b = rest[i + 1].split("=", 1)
            zs.append((name, os.path.abspath(b)))
            i += 2
        elif rest[i] == "--cura":
            cura = True
            i += 1
        elif rest[i] == "--orca":
            orca = True
            i += 1
        elif rest[i] == "--only":
            only = rest[i + 1]
            i += 2
        elif rest[i] == "--reuse":
            reuse = set(rest[i + 1].split(","))
            i += 2
        else:
            raise SystemExit("unknown option " + rest[i])
    os.makedirs(os.path.join(out, "g"), exist_ok=True)
    os.makedirs(os.path.join(out, "png"), exist_ok=True)
    db_path = os.path.join(out, "results.json")
    db = json.load(open(db_path)) if os.path.exists(db_path) else {}
    stls = sorted(f for f in os.listdir(parts) if f.lower().endswith(".stl"))
    if only:
        stls = [f for f in stls if only in f]
    slicers = [(n, lambda stl, g, st, b=b: zslice_slice(b, stl, g, st, out)) for n, b in zs]
    if cura:
        slicers.append(("cura", lambda stl, g, st: cura_slice(stl, g, st, out)))
    if orca:
        slicers.append(("orca", lambda stl, g, st: orca_slice(stl, g, st, out)))
    for f in stls:
        part = f[:-4]
        stl = os.path.join(parts, f)
        for name, fn in slicers:
            for style in ("grid", "tree"):
                key = "%s/%s/%s" % (part, name, style)
                g = os.path.join(out, "g", "%s-%s-%s.gcode" % (part, name, style))
                png = os.path.join(out, "png", "%s-%s-%s.png" % (part, name, style))
                try:
                    if name in reuse and os.path.exists(g) and "slice_s" in db.get(key, {}):
                        dt = db[key]["slice_s"]
                    else:
                        dt = fn(stl, g, style)
                    r = check(stl, g, png=png, title="%s %s %s" % (part, name, style))
                    r["slice_s"] = round(dt, 3)
                except Exception as e:  # report and go on
                    r = {"error": str(e)[:300]}
                db[key] = r
                print(key, json.dumps(r), flush=True)
                json.dump(db, open(db_path, "w"), indent=1)
    write_index(out, db)


def write_index(out, db):
    parts = sorted({k.split("/")[0] for k in db})
    names = []
    for k in db:
        n = k.split("/")[1]
        if n not in names:
            names.append(n)
    h = ["<!doctype html><meta charset=utf-8><title>Support review</title>",
         "<style>body{font:14px sans-serif;margin:16px}table{border-collapse:collapse}"
         "td,th{border:1px solid #ccc;padding:3px 6px;text-align:right}img{max-width:100%;border:1px solid #ddd}"
         "h2{margin-top:32px}</style>",
         "<h1>Support review</h1><p>Unsupported: overhang area (summed over layers, mm&sup2;) with no support "
         "line within 1.5 mm in the 3 layers under it. Floating: support lines with no support, part, or bed "
         "under them. Pictures: front view, side view, top view. Grey part, blue support, cyan interface, "
         "red unsupported overhang, orange floating support.</p>"]
    for style in ("grid", "tree"):
        h.append("<h2>Summary, %s</h2><table><tr><th>part</th>" % style)
        for n in names:
            h.append("<th colspan=4>%s</th>" % html.escape(n))
        h.append("</tr><tr><th></th>" + "<th>unsup mm&sup2;</th><th>float mm&sup2;</th><th>support mm&sup3;</th><th>slice s</th>" * len(names) + "</tr>")
        for p in parts:
            h.append("<tr><td style=text-align:left><a href='#%s'>%s</a></td>" % (p, p))
            for n in names:
                r = db.get("%s/%s/%s" % (p, n, style), {})
                if "error" in r or not r:
                    h.append("<td colspan=4>%s</td>" % html.escape(r.get("error", "-")[:60]))
                else:
                    h.append("<td>%.0f (%.1f%%)</td><td>%.0f</td><td>%.0f</td><td>%.2f</td>" % (
                        r["unsupported_mm2"], r["unsupported_pct"], r["floating_mm2"], r["support_mm3"], r.get("slice_s", 0)))
            h.append("</tr>")
        h.append("</table>")
    for p in parts:
        h.append("<h2 id='%s'>%s</h2>" % (p, p))
        for style in ("grid", "tree"):
            for n in names:
                fn = "png/%s-%s-%s.png" % (p, n, style)
                if os.path.exists(os.path.join(out, fn)):
                    h.append("<div><img src='%s' loading=lazy></div>" % fn)
    open(os.path.join(out, "index.html"), "w").write("\n".join(h))


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    cmd = argv[1]
    if cmd == "check":
        png = None
        if "--png" in argv:
            png = argv[argv.index("--png") + 1]
        r = check(argv[2], argv[3], png=png, title=os.path.basename(argv[3]))
        print(json.dumps(r, indent=1))
    elif cmd == "parts":
        os.makedirs(argv[2], exist_ok=True)
        for k, v in standard_parts().items():
            write_stl(os.path.join(argv[2], k + ".stl"), v)
    elif cmd == "rotate":
        t = read_stl(argv[2])
        for r in argv[4:]:
            t = rotate(t, r[0], float(r[1:]))
        t[:, :, 2] -= t[:, :, 2].min()
        write_stl(argv[3], t)
    elif cmd == "orca-profiles":
        orca_profiles(argv[2], argv[3])
    elif cmd == "review":
        review(argv[2:])
    elif cmd == "index":
        write_index(argv[2], json.load(open(os.path.join(argv[2], "results.json"))))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
