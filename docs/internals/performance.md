# Speed: the lower bound of a slice

This page gives the least time that a slicer needs for one part, and the time of zslice against it. Use it to find the stage that is furthest from its bound before you tune a stage.

The part is the 3DBenchy with the default settings. The machine is an Intel Core i7-6700K (4 cores, 8 threads, 8 MB of L3 cache). The date of the numbers is 2026-11-21.

## The input and the output

A slice reads the mesh and writes the G-code. Each number below is a count from the files or from the slice.

| Item | Size |
|---|---|
| The STL file | 11 255 184 bytes, 225 102 triangles |
| The layers | 239 |
| The crossings of a triangle and a layer plane | 275 662 (each gives one outline segment) |
| The G-code | 2 765 484 bytes, 93 970 moves, 283 158 numbers |
| The offsets of the plan | 2885 calls, 265 420 points in, 205 892 points out |
| The booleans of the plan (the offsets have their own) | 4857 calls, 1 097 282 points in, 401 428 points out |
| The gap fill lines | 215 calls, 29 689 points in, 8102 points out |

## The machine

A small C program measured these rates on one thread. Other programs used the machine during the measurement (a load average of 13), so each rate is the best of nine runs. A second measurement with more load gave rates up to three times as slow.

| Operation | Rate |
|---|---|
| Memory: a copy of 256 MB | 14.3 GB/s of traffic on 1 thread, 16.0 GB/s on 8 threads |
| Memory: the triad of the STREAM test (a = b + 3 c) | 11.4 GB/s on 1 thread, 12.4 GB/s on 8 threads |
| A G-code move from three integers (`G1 X Y E`) | 31.1 ns, 10.4 ns for each number, 935 MB/s |
| The STL file to nine floats for each triangle | 1.58 ms, 7.0 ns for each triangle |
| The cut of all triangles by all layer planes | 5.71 ms, 20.7 ns for each segment |
| A radix sort of 64-bit keys | 22.2 ns for each key |
| The normal of an edge and the moved point of a corner | 24.6 ns for each point |
| The crossing of an edge and a scan line | 34.0 ns for each crossing, 6.35 ns for each edge |
| A crossing test of two edges (four orientations) | 3.13 ns for each pair |

The memory test follows the STREAM test (see [Papers and algorithms](../references/papers-and-algorithms.md)).

## The bound of each stage

The bound of a stage is the count of its work items times the measured rate of the fastest kernel for one item. A stage that needs an order of its items gets one radix sort. The bound is for one thread.

| Stage | The least work | Bound |
|---|---|---|
| Mesh cut | 275 662 segments x 20.7 ns, and one sort of the segments to chain them (275 662 x 22.2 ns) | 5.7 + 6.1 = 11.8 ms |
| Offsets | For each of 265 420 points: the moved point (24.6 ns), one grid key (22.2 ns), and 4 pair tests (12.5 ns). The offsets inside other stages add a quarter (an estimate). | 15.7 x 1.25 = 20 ms |
| Booleans | For each of 1 097 282 points: one sort key (22.2 ns), 4 pair tests (12.5 ns), and the winding and the output (10 ns, an estimate) | 49 ms |
| Gap fill | A center line needs an order of its 29 689 sites: 29 689 x 14.9 steps x 10 ns (an estimate) | 5 ms |
| Fill lines, seams, order | 55 878 line ends x 34 ns, 401 428 region points x 6.35 ns, and the order of the paths (2 ms, an estimate) | 6.5 ms |
| G-code text | 283 158 numbers x 10.4 ns | 2.9 ms |
| Total, one thread | | 95 ms |
| Total, 4 cores | Each stage works on one layer at a time. An outline of 1000 points is 16 kB, and a core has 256 kB of L2 cache. | 24 ms |

Three more bounds help to read the table:

- **The memory bound.** A slicer that only reads the mesh and writes the G-code moves 14 MB. At 12 GB/s that is 1.2 ms. The G-code alone is 0.23 ms. No stage is near the memory bound, so the stages are limited by the instructions for each point.
- **The line cut form.** The skin of all layers from line cuts needs 18.5 ms on one thread (`zslice bench --only dexel`, measured with the same load). The intersections are 788 895 of the points into the booleans, and 35 ms of their bound. With line cuts in their place the total is 95 - 35 + 18.5 = 79 ms on one thread and 20 ms on 4 cores. The skin lines at thin pieces then differ from the lines of today.
- **A desktop with 16 cores.** With cores 2.2 times as fast as the cores of this machine (an assumption: no such machine was measured), the bound is 95 / 2.2 / 16 = 2.7 ms.

A GPU can run the mesh cut, the line cuts, and a distance field. Each of these is a pass with no branch on the data. The compute time of each pass is far below 1 ms. The time of a pass is then the start of the pass and the copy of its result to the CPU: about 1 ms for each stage (an estimate). The order of the paths, the chains of the loops, and the G-code text stay on the CPU.

## zslice against the bound

The time of a full slice is 1477 ms of CPU (`zslice bench --only full --runs 5`, the median of three rounds). The share of each stage comes from a callgrind profile of `zslice slice`.

| Stage | Now (CPU) | Bound | Ratio |
|---|---|---|---|
| Mesh cut, with the face index | 77 ms | 11.8 ms | 6.5 |
| Offsets | 563 ms | 20 ms | 28 |
| Booleans outside the offsets | 471 ms | 49 ms | 9.6 |
| Gap fill (Arachne, without its offsets and booleans) | 215 ms | 5 ms | 43 |
| Fill lines, seams, order, and the search for gaps | 116 ms | 6.5 ms | 18 |
| G-code text and motion plan | 36 ms | 2.9 ms | 12 |
| Total | 1477 ms | 95 ms | 15.5 |

The gap fill and the offsets are furthest from their bounds. Together with the booleans they are 85 % of the time.

- **Gap fill.** The exact path of the Voronoi circle events makes 2.25 M products of long integers for one 3DBenchy. Most of them have one or two chunks of 32 bits, and are one CPU product (`voronoi_ctypes.ExtendedIntN`).
- **Offsets.** Each closing corner adds a loop through the vertex of the outline, and the loops of corners next to each other cross. The unions of the 2885 offsets find 585 000 split points on 434 000 edges. A split point is rounded, so a second search follows. The later searches are a third of the time of the offsets, and they find 5120 more split points.
- **Booleans.** A layer has 13 intersections on average (3112 for 239 layers). For the skin, the plan cuts the inner area of a layer with the surface of each layer near it (`layer.Memo.part`).

## The outline tolerance

The cost of each stage follows the count of the outline points. The slicer removes the points within `engine.resolution` (0.005 mm) of a straight line before all other work (`geom.simplifyClosed`). A larger value gives fewer points to each offset, boolean, and line of G-code.

The 3DBenchy, with the outer walls compared to the walls at 0.005 mm (`tools/gcode_distance.py`, the distance of each end and each middle of a bead segment to the nearest bead of the other file):

| `engine.resolution` | Outline points | Points into the offsets | Points into the booleans | CPU of a full slice | G-code | Outer wall: median, 99 % | Points over 0.1 mm |
|---|---|---|---|---|---|---|---|
| 0.005 mm (the default) | 35 739 | 265 420 | 1 097 282 | 1477 ms | 2.77 MB | | |
| 0.010 mm | 25 790 | 192 039 | 815 679 | 1200 ms (19 % less) | 2.24 MB | 3.2 µm, 10.4 µm | 55 of 174 162 |
| 0.025 mm | 17 538 | 133 477 | 596 216 | 951 ms (36 % less) | 1.78 MB | 9.4 µm, 25.0 µm | 85 of 151 734 |
| 0.050 mm | 13 840 | 107 757 | 490 194 | 852 ms (42 % less) | 1.57 MB | 20.4 µm, 49.8 µm | 129 of 141 084 |

- The outer walls stay within the tolerance for 99 % of their points. The few points over 0.1 mm are short pieces of wall that one of the two slices has and the other does not: a loop at the limit of the least size.
- The skin and the fill change more: a line at a threshold appears or goes (11 % of the skin points move more than 0.05 mm at 0.010 mm).
- The gap fill does not get faster: 215 calls and 260 to 335 ms on one thread at each value.
- The gain depends on the mesh. The bunny of the test parts has long edges: its outlines have 17 014 points at 0.005 mm and 16 622 at 0.025 mm, and its slice needs 1312 ms of CPU at each value.

A rule with a least segment length and a largest deviation, as Cura has it, is weaker than the rule of zslice. The rule of zslice removes a point within the tolerance for an edge of any length. With a limit of 0.5 mm for the new edge and a tolerance of 0.025 mm, the 3DBenchy keeps 27 793 points. The plain tolerance of 0.010 mm keeps 25 790 points with less than half the error.

The default stays at 0.005 mm. A change of the default changes the G-code of each part, so it is a decision of the owner.

## Rules

- Compare CPU times when other programs use the machine. The wall time of a full slice was 500 to 680 ms during these measurements, and its CPU time changed by less than 1 % between rounds.
- Compare instruction counts too (`perf stat -e instructions:u`) for a change of less than 3 %.
- A change of a stage must give the same G-code, byte for byte, or it goes behind a setting that is off.
