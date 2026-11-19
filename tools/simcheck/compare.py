#!/usr/bin/env python3
"""Compare two simulated prints of the same part by their statistics.

A change of the solver (a larger step, sleeping runs) moves single
masses: a falling strand that touches down one step later lands in
another place, and the model itself changes that much when its step
changes from 2 to 1 ms. So two runs compare by what a print shows:

- the moved paths: the paths with a mass that set more than 0.1 mm
  (half a layer) under its place;
- the failed layers: the layers with a mass that set more than 1.5 mm
  under its place (print_sim fail_drop);
- the largest drop of each layer.

A layer that failed in both runs is a mess of strands in both: its paths
do not count, only that it failed. The drop of a failed layer does not
count either. The edge of a failed
region can move by one layer: a layer that failed in one run only counts
only if no layer next to it failed in both runs.

The tolerances come from the model itself: from a step of 2 ms to a step
of 1 ms, 3DBenchy changes 4 of 173 moved paths and a largest drop of a
layer by 0.81 mm, and the calibration overhang fins a drop by 0.36 mm.

Usage: compare.py A.csv B.csv [--drop-tol MM] [--path-tol N]. The files
come from `zslice bench PART --only sim --runs 1 -o FILE`. Prints the
differences, and exits 1 if they pass the tolerances: more than
--path-tol paths that moved in one run only (default 3 % of the moved
paths, at least 3), a failed layer in one run only (out of the edge of a
failed region), or a layer whose largest drop differs by more than
--drop-tol mm (default 1).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import csv
import sys

MOVED = 0.1
FAILED = 1.5


def stats(path):
    f = open(path)
    f.readline()
    moved = set()
    failed = set()
    drop = {}
    for r in csv.DictReader(f):
        if r["feature"] == "infill":
            continue
        d = float(r["wz"]) - float(r["z"])
        layer = int(r["layer"])
        drop[layer] = max(drop.get(layer, 0.0), d)
        if d > MOVED:
            moved.add((layer, int(r["path"])))
        if d > FAILED:
            failed.add(layer)
    return moved, failed, drop


def main():
    args = sys.argv[1:]
    drop_tol = float(args[args.index("--drop-tol") + 1]) if "--drop-tol" in args else 1.0
    a_moved, a_failed, a_drop = stats(args[0])
    b_moved, b_failed, b_drop = stats(args[1])
    path_tol = int(args[args.index("--path-tol") + 1]) if "--path-tol" in args else max(3, (3 * len(a_moved)) // 100)
    both_failed = a_failed & b_failed
    only = {p for p in a_moved ^ b_moved if p[0] not in both_failed}
    failed_only = sorted(l for l in a_failed ^ b_failed if not ({l - 1, l + 1} & both_failed))
    worst = 0.0
    worst_layer = None
    for layer in set(a_drop) | set(b_drop):
        # A failed layer counts by the failed layers above.
        if layer in a_failed or layer in b_failed:
            continue
        d = abs(a_drop.get(layer, 0.0) - b_drop.get(layer, 0.0))
        if d > worst:
            worst, worst_layer = d, layer
    print(f"moved paths {len(a_moved)} and {len(b_moved)}, in one run only {len(only)} (tolerance {path_tol})")
    print(f"failed layers {len(a_failed)} and {len(b_failed)}, in one run only {failed_only}")
    print(f"largest difference of the largest drop of a layer: {worst:.3f} mm (layer {worst_layer}, tolerance {drop_tol})")
    ok = len(only) <= path_tol and not failed_only and worst <= drop_tol
    print("same" if ok else "DIFFERENT")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
