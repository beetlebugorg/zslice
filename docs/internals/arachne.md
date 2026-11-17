# Arachne walls

With `project.wall_generator = arachne`, the walls of each layer come from Arachne, the variable-width wall method of Cura. The code is a port to Zig of CuraEngine (AGPL-3.0-or-later). The Voronoi diagram is a port of boost::polygon (Boost Software License 1.0). See `REFERENCES.md` for the files, the commit hashes, and the copyright lines.

## Why

A classic wall is the outline moved in by a whole number of line widths. A part that is 1.0 mm thick, with 0.44 mm lines, gets two lines and a gap of 0.12 mm in the middle. A part thinner than one line gets no wall, or a thin wall loop (`thin_walls`). Arachne measures the thickness of the part at each point, and fills it with a whole number of lines whose widths add up to the thickness. Where the bead count changes (a wedge), one line splits into two, or two lines join into one, over a short transition.

## The method

The files are in `src/arachne/`. Each file explains its part in its header comment.

1. `walls.zig` cleans the outline: an opening and a closing remove slivers, small areas go, a simplify removes the points within 25 µm of a line, and a union removes crossings.
2. `../voronoi.zig` makes the Voronoi diagram of the outline segments, with a sweep line and robust predicates (a port of boost::polygon). Each cell belongs to one segment or to one vertex of the outline.
3. `skeletal.zig` turns the inside part of the diagram into a graph of "quads": for each cell, a chain of edges from the outline up to the center line and back. Each node knows its distance R to the outline. A curved Voronoi edge (between a vertex and a segment) becomes short straight pieces.
4. An edge is central if R grows slowly along it. The central edges get a bead count from the beading strategy (`beading.zig`) for the thickness 2R. Where the count changes, a transition gets a new node at each end, with a rib to the outline.
5. Each node gets a beading: the width and the distance from the outline of each bead. The beadings spread from the central nodes to the other nodes.
6. On each rib, each bead gets a junction (a point and a width). The junctions of each quad join into line pieces, one list for each wall.
7. `walls.zig` stitches the pieces into lines and loops (`extrusion.zig`), removes tiny odd lines, and simplifies the lines. The beads of width 0 are not printed: they mark the inner edge of the walls. Their loops make the inner area, for the skin and the infill.

The beading strategy is the chain of CuraEngine `makeStrategy`: distributed, redistribute (the outer walls keep their width), widening (a thin part gets one line of at least `min_bead_width`), the outer wall inset, and limited (at most 2 x `wall_count` beads, and the 0-width marker).

## The settings

The names follow Cura. A value of 0 uses the Cura default for the nozzle and the line width:

| zslice | Cura | Default |
|---|---|---|
| `min_wall_line_width` | `min_wall_line_width` (`min_even_wall_line_width`, `min_odd_wall_line_width`) | 0.85 x the nozzle diameter |
| `min_feature_size` | `min_feature_size` | 1/4 of the line width |
| `min_bead_width` | `min_bead_width` | `min_wall_line_width` |
| `wall_transition_length` | `wall_transition_length` | the line width |
| `wall_transition_angle` | `wall_transition_angle` | 10 degrees |
| `wall_transition_filter_distance` | `wall_transition_filter_distance` | 100 mm |
| `wall_distribution_count` | `wall_distribution_count` | 1 |

Fixed values, as the Cura defaults: `fill_outline_gaps` is on (thin parts print), `wall_transition_filter_deviation` is 1/4 of the nozzle diameter, the discretization step is 0.8 mm, and the simplify uses `meshfix_maximum_resolution` 0.5 mm, `meshfix_maximum_deviation` 0.025 mm, and `meshfix_maximum_extrusion_area_deviation` 50000 µm². The outer and inner walls have the same line width. All Arachne settings can change per layer.

Not ported: the "fluid motion" smoothing of the outline (`meshfix_fluid_motion_enabled`). The inner wall inset (`wall_x_inset`, 0 in Cura) is in the strategy, with no setting.

## In the layer plan

`layer.regions` keeps the Arachne result of each layer in its memo (`Memo.arachneWalls`), by the settings. `Regions.var_walls` has the lines of each wall, with a width for each point. The inner area replaces the classic inner offset, with its own memo key (`arachneDelta`), so the skin and the infill memos work as before.

The plan prints the walls in the classic order: in each island, the inner walls from the inside out, then the outer wall. The loops of a wall start at their seam (`project.seam`), as the classic loops. The open lines of a wall (the odd lines in the middle of a thin part, and the pieces of a wall that does not close) come after its loops, in the nearest order. CuraEngine prints the even walls clockwise around the part. The plan turns them, so that they go counterclockwise around the part, as the classic walls.

A path with a width for each point has `Path.w_start`, and its widths are in `LayerPlan.point_w`. The G-code writer extrudes each segment with the mean width of its two ends and the bead model of `flow.zig`. The speed limit of `filament.max_flow` uses the widest point of the path. The preview gets the bead area of each point in `Toolpaths.point_area` (with the z of the layer in `point_z`), as the slope smoothing beads, and draws each segment with its own width.

## Tests

- `src/voronoi.zig`: the diagram against a brute force check on random points and segments.
- `src/arachne/beading.zig`: the bead counts and widths for known thicknesses.
- `src/arachne/walls.zig`: a 1.2 mm wall with 0.4 mm lines gets 3 beads of 0.4 mm; a 0.3 mm fin gets one narrow bead; a wedge gets a bead count that goes up along it.

The [CuraEngine test](cura-compare.md#testing-against-curaengine) can compare the walls with CuraEngine, which also uses Arachne.
