#!/usr/bin/env python3
"""Fill the measurement sheet with the values that the print simulation
predicts for the calibration parts (see gen.py and README.md).

For each part, `zslice bench PART.stl --only sim --runs 1 -o PART.masses.csv`
writes the masses that moved in the simulated print: the place where the
slicer meant each mass to be (wx, wy, wz) and the place where it set
(x, y, z). This script maps the features of gen.py (features.tsv) onto
the bed, finds the masses of each feature (but not the infill, which
is inside the part), and writes sheet.csv: one row
for each thing to measure, with the predicted value and an empty column
for the measured value.

The predictions:

- overhang: the thickness of the fin tip (2 mm in the model) plus the
  largest drop of a mass in the last 2 mm of the fin; and a grade of the
  underside from the largest drop in the fin.
- bridge: the thickness of the deck in the middle third of the span
  (1.6 mm in the model) plus the largest drop there; and if loose
  strands hang under the deck (a drop of more than 1.5 mm).
- ledge: the thickness of the slab in its last 2 mm plus the largest
  drop there, the height of the bottom of the tip over the bed, and if
  the slab falls in strands (a drop of more than 1.5 mm).

Usage: predict.py DIR [--label TEXT] [--sheet FILE]. DIR has the STL
files, features.tsv, and the masses files. Writes FILE (default
DIR/sheet.csv), and keeps the measured values and the notes of FILE if
it exists.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import csv
import os
import struct
import sys

FIN_TIP = 2.0
DECK = 1.6
# A mass that sets more than this under its place is a loose strand (the
# fail_drop of print_sim.zig).
FAIL_DROP = 1.5


def stl_bounds(path):
    with open(path, "rb") as f:
        f.read(80)
        (n,) = struct.unpack("<I", f.read(4))
        lo = [float("inf")] * 3
        hi = [float("-inf")] * 3
        for _ in range(n):
            rec = struct.unpack("<12fH", f.read(50))
            for k in range(3):
                p = rec[3 + 3 * k: 6 + 3 * k]
                for i in range(3):
                    lo[i] = min(lo[i], p[i])
                    hi[i] = max(hi[i], p[i])
    return lo, hi


def read_masses(path):
    box = None
    rows = []
    with open(path) as f:
        first = f.readline()
        box = [float(v) for v in first.split()[3:7]]
        for r in csv.DictReader(f):
            rows.append(r)
    return box, rows


def thickness(nominal, drop):
    """The thickness that calipers measure: the nominal thickness plus the
    drop of the lowest bead, or "strands" if it fell loose."""
    if drop > FAIL_DROP:
        return "strands"
    return f"{nominal + max(drop, 0):.2f}"


def grade(drop):
    if drop < 0.1:
        return 0
    if drop < 0.3:
        return 1
    if drop < FAIL_DROP:
        return 2
    return 3


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: predict.py DIR [--label TEXT]")
    d = sys.argv[1]
    label = sys.argv[sys.argv.index("--label") + 1] if "--label" in sys.argv else "sim"
    sheet = sys.argv[sys.argv.index("--sheet") + 1] if "--sheet" in sys.argv else os.path.join(d, "sheet.csv")
    feats = list(csv.DictReader(open(os.path.join(d, "features.tsv")), delimiter="\t"))
    parts = {}
    for name in sorted({f["file"] for f in feats}):
        lo, hi = stl_bounds(os.path.join(d, name))
        box, masses = read_masses(os.path.join(d, name.replace(".stl", ".masses.csv")))
        # The slicer centers the part and scales it in x and y for the
        # shrinkage of the plastic.
        sx = (box[2] - box[0]) / (hi[0] - lo[0])
        sy = (box[3] - box[1]) / (hi[1] - lo[1])
        to_part = []
        for m in masses:
            # The infill is inside: calipers and photos do not see it.
            if m["feature"] == "infill":
                continue
            wx = lo[0] + (float(m["wx"]) - box[0]) / sx
            wy = lo[1] + (float(m["wy"]) - box[1]) / sy
            wz = float(m["wz"])
            to_part.append((wx, wy, wz, wz - float(m["z"])))
        parts[name] = to_part

    def drops(name, x0, x1, y0, y1, z0, z1):
        return [m[3] for m in parts[name] if x0 <= m[0] <= x1 and y0 <= m[1] <= y1 and z0 <= m[2] <= z1]

    out = []
    for f in feats:
        kind = f["kind"]
        size = f["size"]
        x0, x1, y0, y1, z0, z1 = (float(f[k]) for k in ("x0", "x1", "y0", "y1", "z0", "z1"))
        if kind == "overhang":
            tip = max(drops(f["file"], x0, x1, y1 - 2, y1, z0, z1), default=0.0)
            all_ = max(drops(f["file"], x0, x1, y0, y1, z0, z1), default=0.0)
            out.append(("overhang", size + " deg", "tip thickness", "mm", "calipers on the fin tip, at the end", thickness(FIN_TIP, tip)))
            out.append(("overhang", size + " deg", "underside", "0-3", "0 smooth, 1 a little rough, 2 rough or drooped, 3 loose strands", str(grade(all_))))
        elif kind == "bridge":
            third = (x1 - x0) / 3
            mid = max(drops(f["file"], x0 + third, x1 - third, y0, y1, z0, z1), default=0.0)
            out.append(("bridge", size + " mm", "deck thickness at the middle", "mm", "calipers across the deck at the middle of the span", f"{DECK + max(mid, 0):.2f}"))
            out.append(("bridge", size + " mm", "loose strands under the deck", "yes/no", "look under the deck", "yes" if mid > FAIL_DROP else "no"))
        elif kind == "ledge":
            tip = max(drops(f["file"], x1 - 2, x1, y0, y1, z0, z1), default=0.0)
            out.append(("ledge", size + " mm", "tip thickness", "mm", "calipers on the slab, 1 mm from its end", thickness(DECK, tip)))
            out.append(("ledge", size + " mm", "height of the tip bottom", "mm", "calipers depth rod from the bed to the bottom of the tip", "on the bed" if tip > FAIL_DROP else f"{z0 - max(tip, 0):.2f}"))
            out.append(("ledge", size + " mm", "falls in strands", "yes/no", "look at the slab", "yes" if tip > FAIL_DROP else "no"))
    # Keep the measured values and the notes of a sheet that exists.
    kept = {}
    if os.path.exists(sheet):
        for r in csv.reader(open(sheet)):
            if len(r) >= 8 and r[0] != "part":
                kept[(r[0], r[1], r[2])] = r[6:8]
    with open(sheet, "w", newline="") as o:
        w = csv.writer(o)
        w.writerow(["part", "feature", "measure", "unit", "how", f"predicted ({label})", "measured", "notes"])
        for r in out:
            w.writerow(list(r) + kept.get((r[0], r[1], r[2]), ["", ""]))


if __name__ == "__main__":
    main()
