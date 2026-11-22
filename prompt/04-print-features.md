# 04. Print features

## Goal

Build the features of a layer plan, in the order of how often a print needs them: walls, skin, infill, support, bridges, seams, gap fill, Arachne walls, and the newer features. At the end, the features of the roadmap section "Print quality and strength" and "Motion and extrusion" work, except the ones it marks open.

## Read first

- [The roadmap](../ROADMAP.md), section "Feature parity with PrusaSlicer and Cura": which features exist and which stay open (adaptive cubic, adaptive layer height, arc fitting, an ooze shield, mesh repair). Sequential printing is done.
- [The settings reference](../docs/user/settings.md), sections Walls, Top and bottom skin, Infill, Ironing, Slope smoothing, Support, Skirt and brim, Experimental.
- [How a slicer works](../docs/internals/how-slicing-works.md), [Arachne walls](../docs/internals/arachne.md), [Contributing](../docs/internals/contributing.md) (how to add a setting, a feature, or an infill pattern).
- [Add support](../docs/user/support.md), [Check the print](../docs/user/check.md).
- [Cura](../docs/references/cura.md), [OrcaSlicer](../docs/references/orcaslicer.md), [Slicer techniques](../docs/references/slicer-techniques.md).

## Build

1. `src/layer.zig`: the plan of one layer. The ten steps are in its header: walls, the inner area, skin from the top and bottom surfaces of each layer, sparse infill, fill, ironing, skirt and brim, support, order, and slope smoothing. Each layer reads only the outlines of the other layers, so layers plan in parallel.
2. Skin: find it from the top surface (outline j less outline j + 1) and the bottom surface of each layer, one boolean for each pair of layers. Do not intersect the outlines of all layers above and below. Skin patterns: lines, monotonic, concentric; the skin angle and its turn per layer. Retractless skin joins its pieces into few paths along the walls.
   - A hole or a step in the outline cuts a skin island into pieces. Of two lines of different pieces on the same scan line, the shorter line gives way where they overlap, so the shared border gets one line.
   - A link along the wall (the turn of a zigzag, and the walk of retractless skin) has half the bead area of a line. The line ends already fill the inner half of its bead.
   - The skin area loses a band of one line width around each bridge move, so the skin beads start where the bridge beads end. The gap fill of the skin does not count the bridge beads as a gap.
3. `src/infill.zig`: scanline fill on one grid for all layers, so that lines stack. Patterns: `lines`, `grid` (default), `triangles`, `trihexagon`, `cubic`, `gyroid`, `concentric`, `honeycomb`, `zigzag`, `flow`, `lightning` (`src/lightning.zig`). Curved patterns fill the bounding box, then `src/clip_open.zig` clips the open lines. Infill ribs: a line in each narrow infill area that a sparse infill misses. Combined infill prints the sparse area of a group of layers once, as one tall bead.
4. `src/support.zig`: overhangs from `support_angle`, columns from the top down, the Z gap and the XY gap, interface layers. `project.support`: `off` (default), `everywhere`, `buildplate`. `project.support_style`: `grid` (default), `tree`, `bridge` (a sacrificial pad under each overhang only). `src/tree_support.zig`: planned trees, so that equal overhangs get equal trees, with no dependence on the order of nodes or threads. `src/support_skeleton.zig` and `src/support_edit.zig`: the trees as data, and edits by hand.
5. Bridges: find them, and print them with their own direction, speed, flow, and fan. Bridges for skin and for walls.
6. Seams: `project.seam` `hidden` (default), `sharpest`, `rear`, `nearest`, `random`. Hidden is the most hidden point: inside corners over about 1 mm, the back, and no point over air; ties go to the back, so the seams line up. `cornerSeamIndex` is a port of the seam corner choice of CuraEngine, with its copyright and license kept.
7. `src/gapfill.zig` and thin walls: lines in narrow areas that no wall or skin covers.
8. Arachne (`src/arachne/`, `src/voronoi*.zig`): `project.wall_generator = arachne`. A port of CuraEngine: the Voronoi diagram of segments with robust predicates, skeletal trapezoidation, beading strategies, and the clean-up of the lines. Classic walls stay the default until test prints approve Arachne.
9. The newer features:
   - Wall order (`project.wall_order`: `inner_first` default, `outer_first`) and an extra wall on alternate layers (`project.alternate_extra_wall`).
   - Overhang walls: the parts of a wall over air print at `project.overhang_wall_speed` times the wall speed with `project.overhang_wall_fan`. A wall a whole line over air prints as a bridge.
   - Fuzzy skin (`project.fuzzy_skin`: `off`, `outer_wall`, `outside`).
   - Spiral vase (`project.spiral_vase`): a layer that starts with a rising outer wall has no Z move of its own.
   - Polyholes (`project.polyholes`): round holes become the polygons of nophead, in pass 1.
   - Coasting (`project.coasting_volume`, `project.coasting_speed`).
   - Wipe on retraction (`project.retract_wipe`) and along the start of a closed outer wall (`project.outer_wall_wipe`).
   - Slope smoothing and slope ironing (`src/slope.zig`): beads that fill the steps of a sloped top, then ironing over them.
   - Size compensation: XY offset, hole offset, elephant foot, shrinkage.
   - One part at a time (`project.print_sequence = by_object`; default `by_layer`): the plate job makes the levels of one part at a time, in the order of the plate list. The first level of each later part lifts the head over the printed parts, moves to the new part, and goes down. Each part starts with the fan off. Such a plate has no prime tower and no move streams. `machine.clearance_radius` and `machine.clearance_height` (40 mm each, the defaults of OrcaSlicer) are the head model. Arrange keeps the radius between parts. `zs_app_part_reorder` moves a part in the order.
   - The comb area of each layer plan (`project.combing_mode`, part 03): the part with no skin, the part with no top surface, or the sparse infill, with half a line width more around the skin.
   - `project.fast_offsets` (section Experimental, default off): a closing corner of an offset gets the crossing point of its two edges. A slice uses about 11 % less CPU. With the switch off, the G-code is the same as before.
10. Checks of a slice: `src/gaps.zig` (solid areas that no bead covers, on a raster of 0.04 mm cells), `src/islands.zig` (shapes that start in the air), and `src/app/checks.zig` (flow over the hot end limit, short layers, and more). The Check looks at the overhangs of every part. With support on, the support of the layers just under a layer holds it too, with the Z gap and the XY gap counted. What still hangs over air is an issue. For build plate support, the issue says that the support cannot reach the overhang, and to use support everywhere or tree support. With one part at a time, the Check names two parts that are too near, and a part over `clearance_height` that does not print last.

## Numbers and rules that matter

- Wall k is the outline moved in by (k + 1/2) line widths. Skin thinner than half a line width goes.
- Order in a layer: skirt and brim, support, then each island (inner walls, outer wall, skin, infill, ironing). The next island and the next path are the nearest to the nozzle.
- On a plate of many parts, the plate job makes one skirt and one brim around all parts.
- Tree support is hollow: the loop only, with its seam at the rear.
- A gap thinner than 3 cells or smaller than the minimum area is left out.
- An island is a polygon with less than 1 % of its area over the layer below.

## Lessons

- Never make a tree branch thinner on the way down. A pass from the top layer down gives each disk at least the radius of the disks above that join it, so a branch is a steady cone.
- Keep tree branches thick enough to print. Keep the radius of a joined node under the largest radius.
- Keep the support out of the skirt and the brim, and out of the brim of a plate of many parts.
- Keep hidden seams on corners that stay. End slope runs short.
- Join monotonic skin only between near scan lines, and only at clean hairpin turns.
- Do not join the extra lines of the flow infill band. Keep them out of narrow band strips.
- Keep islands in holes when the hole offset grows the holes.
- **One skin line on the border of two skin pieces.** Each piece of a skin island put a line on its edges, so two lines lay on a shared border. On a Bambu plate with two openings, these double lines made raised ridges from the corners of the openings to the walls. With the shorter line giving way, the top layer of the test plate has 51.8 mm² of bead on bead in place of 255 mm².
- **Half the plastic for skin links.** At the full line width, each zigzag turn put a dot at the edge of the skin, and each retractless walk put a ridge along the wall. Bambu Studio puts no plastic on the moves between the lines of its top surface.
- **Stop the skin lines half a line width from the bridge beads.** The skin lines ended on the edge of the bridge area, where the bridge lines end too, so a band of one line width had two beads.
- **Report overhangs that the support does not reach.** With support on, the Check skipped the overhangs. Build plate support under a roof that stands over the part makes no support, so the roof printed in the air with no issue.

## Acceptance checks

1. Each pattern, each seam mode, and each support style slices the 3DBenchy and the corpus with status `ok`.
2. A feature that is off gives the same G-code as before it existed.
3. Arachne fills a wedge with a whole number of beads of variable width, and a part thinner than two lines gets a wall.
4. `zslice gaps` and `zslice check` list the gaps and the issues of a part.
5. A 20 mm bridge between two posts prints with its own direction and fan.
6. Equal overhangs get equal trees, also after a mirror of the part.
7. With `print_sequence = by_object`, each part prints from the bottom to the top, then the next part. The default `by_layer` gives the same G-code as before.
8. A roof over the part with build plate support shows in the Check.
9. A top skin with a hole has one line on each border of two pieces.
