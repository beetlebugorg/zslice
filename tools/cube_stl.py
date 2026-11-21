#!/usr/bin/env python3
# Writes an ASCII STL of a box to a path. The CI and release workflows
# slice it to check a build.
#
# Usage: python3 -I tools/cube_stl.py <out.stl> [x y z]
#
# The default box is a 20 mm cube. The sides are bands of 8 mm or less, so
# a test can paint the triangles over a height: web/app/test-node.mjs
# paints the triangles over z = 40 mm, so its box is 48 mm tall.
# SPDX-License-Identifier: AGPL-3.0-or-later
import math
import sys

sx, sy, sz = (float(a) for a in sys.argv[2:5]) if len(sys.argv) >= 5 else (20.0, 20.0, 20.0)
bands = max(1, math.ceil(sz / 8))
zs = [sz * i / bands for i in range(bands + 1)]
ring = [(0, 0), (sx, 0), (sx, sy), (0, sy)]
tris = []
# The bottom faces down and the top faces up (counterclockwise from outside).
tris += [((0, 0, 0), (sx, sy, 0), (sx, 0, 0)), ((0, 0, 0), (0, sy, 0), (sx, sy, 0))]
tris += [((0, 0, sz), (sx, 0, sz), (sx, sy, sz)), ((0, 0, sz), (sx, sy, sz), (0, sy, sz))]
for k in range(4):
    (x0, y0), (x1, y1) = ring[k], ring[(k + 1) % 4]
    for z0, z1 in zip(zs, zs[1:]):
        tris += [((x0, y0, z0), (x1, y1, z0), (x1, y1, z1)), ((x0, y0, z0), (x1, y1, z1), (x0, y0, z1))]
out = ["solid box"]
for t in tris:
    out += ["facet normal 0 0 0", "outer loop"]
    out += ["vertex {:g} {:g} {:g}".format(*p) for p in t]
    out += ["endloop", "endfacet"]
with open(sys.argv[1], "w") as f:
    f.write("\n".join(out + ["endsolid box"]) + "\n")
