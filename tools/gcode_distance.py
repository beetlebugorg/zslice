#!/usr/bin/env python3
"""The distance between the beads of two G-code files of one model.

Usage: python3 -I tools/gcode_distance.py a.gcode b.gcode

A change of the slicer that keeps the shape of each path can still
change the text of the G-code: a point moves by a micrometer, a loop
starts at another vertex, or a point on a straight line goes away. This
tool compares the shapes. For each layer (each Z with beads) and each
feature (the ;TYPE: comment), it has the bead segments of both files
(G1 moves with E above 0, relative E). For each end and each middle of
a segment of one file, it finds the distance to the nearest segment of
the other file on the same layer with the same feature. It does this in
both directions, so the largest value is the Hausdorff distance of the
beads of the feature on the layer.

For each feature, it prints the count of points in each class of
distance, the largest distance with its place, and the bead length in
each file. The G-code has three decimals, so a distance up to 0.0015 mm
counts as one micrometer. The exit status is 1 if a point is farther
than 0.0015 mm.
"""
import math
import sys
from collections import defaultdict

CELL = 1.0  # mm


def beads(path):
    """{(z, feature): [(x0, y0, x1, y1)]} of the bead segments of a file."""
    groups = defaultdict(list)
    x = y = z = 0.0
    feature = ''
    with open(path) as f:
        for line in f:
            if line.startswith(';TYPE:'):
                feature = line[6:].strip()
                continue
            if not line.startswith(('G0', 'G1')):
                continue
            nx, ny, nz, e = x, y, z, 0.0
            for word in line.split(';', 1)[0].split()[1:]:
                c = word[0]
                try:
                    v = float(word[1:])
                except ValueError:
                    continue
                if c == 'X':
                    nx = v
                elif c == 'Y':
                    ny = v
                elif c == 'Z':
                    nz = v
                elif c == 'E':
                    e = v
            if e > 0 and (nx != x or ny != y):
                groups[(round(nz, 4), feature)].append((x, y, nx, ny))
            x, y, z = nx, ny, nz
    return groups


def index(segs):
    grid = defaultdict(list)
    for i, (x0, y0, x1, y1) in enumerate(segs):
        for cx in range(int(math.floor(min(x0, x1) / CELL)), int(math.floor(max(x0, x1) / CELL)) + 1):
            for cy in range(int(math.floor(min(y0, y1) / CELL)), int(math.floor(max(y0, y1) / CELL)) + 1):
                grid[(cx, cy)].append(i)
    return grid


def seg_dist(px, py, s):
    x0, y0, x1, y1 = s
    dx, dy = x1 - x0, y1 - y0
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / l2))
    return math.hypot(px - x0 - t * dx, py - y0 - t * dy)


def nearest(px, py, segs, grid):
    """The distance from a point to the nearest segment: the cells
    around the point, in rings, until a ring is farther than the best."""
    cx, cy = int(math.floor(px / CELL)), int(math.floor(py / CELL))
    best = math.inf
    ring = 0
    while ring <= 400:
        for ix in range(cx - ring, cx + ring + 1):
            for iy in range(cy - ring, cy + ring + 1):
                if max(abs(ix - cx), abs(iy - cy)) != ring:
                    continue
                for i in grid.get((ix, iy), ()):
                    best = min(best, seg_dist(px, py, segs[i]))
        if best <= ring * CELL:
            break
        ring += 1
    return best


def one_way(a, b, counts, worst):
    grid = index(b)
    for (x0, y0, x1, y1) in a:
        for px, py in ((x0, y0), (x1, y1), ((x0 + x1) / 2, (y0 + y1) / 2)):
            d = nearest(px, py, b, grid) if b else math.inf
            k = 0 if d <= 0.0015 else 1 if d <= 0.0055 else 2 if d <= 0.0505 else 3
            counts[k] += 1
            if d > worst[0]:
                worst[0], worst[1] = d, (px, py)


def main():
    a, b = beads(sys.argv[1]), beads(sys.argv[2])
    features = sorted({k[1] for k in a} | {k[1] for k in b})
    bad = 0
    print(f'layers: {len({k[0] for k in a})} and {len({k[0] for k in b})}')
    print(f'{"feature":<12} {"points":>9} {"<= 1 um":>9} {"<= 5 um":>8} {"<= 50 um":>8} {"more":>7} {"largest um":>10}  bead length mm')
    for feature in features:
        counts = [0, 0, 0, 0]
        worst = [0.0, None, None]
        for key in sorted(k for k in set(a) | set(b) if k[1] == feature):
            before = worst[0]
            one_way(a.get(key, []), b.get(key, []), counts, worst)
            one_way(b.get(key, []), a.get(key, []), counts, worst)
            if worst[0] > before:
                worst[2] = key[0]
        length = [sum(math.hypot(s[2] - s[0], s[3] - s[1]) for k, segs in f.items() if k[1] == feature for s in segs) for f in (a, b)]
        place = f' at x {worst[1][0]:.3f} y {worst[1][1]:.3f} z {worst[2]}' if worst[0] > 0.0015 else ''
        print(f'{feature:<12} {sum(counts):>9} {counts[0]:>9} {counts[1]:>8} {counts[2]:>8} {counts[3]:>7} {worst[0] * 1000:>10.1f}  {length[0]:.1f} and {length[1]:.1f}{place}')
        bad += sum(counts[1:])
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
