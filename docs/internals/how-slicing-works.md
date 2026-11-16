# How a slicer works

A slicer turns a 3D model into G-code: the list of moves that a 3D printer makes. This document follows one model through zslice, stage by stage. Each stage names the source file that does it. Each source file explains its method in its header comment.

## 1. Load the mesh (`src/mesh.zig`)

An STL file is a list of triangles. The triangles together make the closed surface of the part. Each triangle has three vertices. Seen from outside the part, the vertices are counterclockwise. This order tells the slicer which side of the surface is outside.

The STL file does not say which triangles share an edge. The slicer needs this information in stage 3. The loader "welds" the vertices: vertices with the same coordinates become one vertex. After the weld, two triangles that touch have the same two vertex numbers on their shared edge.

## 2. Place the part and make the layer table (`src/engine.zig`, `src/slicer.zig`)

The engine moves the part so that its bottom is at z = 0 and its center is at the center of the bed.

The layer table gives the z of each layer. The first layer is usually thicker (0.3 mm), so that it sticks to the bed. The next layers have the layer height (0.2 mm). An override can give the layers with their top in a z range another height. Each layer has a cut plane at the middle of its height. The outline at the middle is the best estimate of the shape of the whole layer.

## 3. Cut the mesh into outlines (`src/slicer.zig`)

Each triangle that crosses a cut plane gives one line segment. The direction of the segment comes from the vertex order, so the outside of the part is always on the same side. Then the slicer joins the segments into closed loops. Two segments join where they come from triangles that share an edge.

The result for each layer is a set of closed polygons:

- An outer boundary is counterclockwise.
- A hole is clockwise.

All later stages use this rule: the material is on the left of each edge.

From here on, all coordinates are integers in micrometers (`src/geom.zig`). With integers, a test such as "is this point left of this line" always gives the same answer. With floating point, two places in the code can get different answers for the same test, and the polygon operations then make broken shapes.

A mesh can have holes, from a bad export or a bad repair. Then some segments do not join into loops. The slicer joins the open chains across small gaps, and removes the chains that it cannot close.

## 4. Polygon tools (`src/clip.zig`, `src/offset.zig`)

The next stages use two tools on polygons.

**Booleans** (`clip.zig`): union, intersection, and difference of two polygon sets. The method:

1. Split all edges where they cross or touch.
2. For each edge, count how many times each polygon set surrounds the area on each side of it (the "winding number").
3. Keep the edges that have "inside" on one side and "outside" on the other side.
4. Join the kept edges into loops.

**Offset** (`offset.zig`): move each boundary in or out by a distance. Each edge moves along its normal. The corners get joins. Where the moved edges cross (an inside corner, or a shape that becomes too small), a union removes the parts that turn the wrong way.

## 5. Plan each layer (`src/layer.zig`)

The plan of a layer has the paths that the nozzle follows.

**Walls.** The nozzle makes a line of plastic about 0.45 mm wide. The center of the outer wall is half a line width inside the outline, so the outside of the plastic is on the outline. Each next wall is one line width further in.

**Skin.** The top and bottom of a part must be solid. The other parts can be hollow, with a sparse infill. For each layer, the slicer looks at the layers above and below:

- A point is "supported" if it is inside the part in each of the next few layers above (the top thickness) and below (the bottom thickness).
- Skin is the area inside the walls minus the supported area.
- Sparse infill is the remaining area.

**Fill.** Skin gets lines one line width apart. Sparse infill gets lines further apart, from the density. The fill uses a scanline method (`src/infill.zig`): turn the shape so that the lines are horizontal, find where each line crosses the polygon edges, and keep the parts of the line that are inside. All layers use the same line grid, so the infill lines of each layer are on top of the lines below.

**Ironing** (if on). The top surfaces of a layer are its outline minus the outline of the layer above. After the other paths, the nozzle goes over the top surfaces again with close lines and a small flow, to melt the surface flat.

**Slope smoothing** (if on, `src/slope.zig`). A sloped top surface prints as a stair: each layer is a little smaller than the layer below, so the layer below has a narrow flat ledge outside it. In a cut across the edge, each step has an empty triangle between the corner and the ideal surface, with the area h x L / 2 (h: the layer height, L: the ledge width). After all other paths of a layer, the nozzle goes back along the edge of the layer and lays one bead in each corner, with the volume of the triangle. The bead is over the middle of the ledge, and its top is at half the step height. The nozzle is a cone on a flat tip. Where the cone has no room there, the nozzle stays higher, up to the top of the layer. So each point of the bead has its own Z, between the two layers. The normal paths of each layer stay planar. A ledge wider than `slope_smoothing_max_width` line widths is a flat top, and a ledge with no ledge above or below it is a shelf: they get no bead.

**Order.** The nozzle prints the part one island after the other. An island is an outer boundary of the layer with its holes. In each island, the nozzle prints the inner walls, then the outer wall, then the skin, then the infill, then the ironing. Then it goes to the nearest island that is not done. A move between two islands leaves the part and retracts, so this order has the fewest of these moves. In each group, the next path is the nearest one to the nozzle.

## 6. Write G-code (`src/gcode.zig`)

For each path, the slicer writes:

1. A travel move (`G0`) to the start of the path. Before a long travel, the extruder pulls the filament back a little (a retraction), so that the nozzle does not ooze on the way.
2. An extrusion move (`G1 ... E`) for each segment. E is the length of filament to push. The nozzle presses the plastic on the layer below, so the bead has a flat top and bottom and round sides: its cross section is a rectangle with a half circle on each side, with the area (w - h) x h + pi x h^2 / 4 (`src/flow.zig`). The volume is that area times the length. The filament is a cylinder, so the filament length is that volume divided by the area of the filament circle.

The speed of each move comes from limits (`src/settings.zig`). The machine has a maximum speed. The filament has a maximum flow: the volume of plastic that the hot end can melt in one second. A wide, tall line uses more flow for each millimeter, so it must go slower. The project gives a ratio of the allowed speed for each feature. For example, the outer wall goes at 50 % of the allowed speed, for a better surface.

A slope smoothing path has a Z at each point. The nozzle goes down to its first point, writes `G1 X Y Z E` for each segment, and goes back up to the layer at the end. The speed and the acceleration of these moves are limited so that Z stays within `max_z_speed` and `max_z_accel`.

**Time.** The slicer plans the speed of each move as the printer firmware does (see `motion.zig`): each move speeds up and slows down with the acceleration, and each corner has a speed limit from its angle. Retractions and Z moves are stops.

**Cooling.** Each layer must cool before the next layer goes on it. Before the slicer writes a layer, it plans the time of the layer. If the time is less than the minimum layer time of the filament, the extrusions of that layer go slower, but not below a minimum speed. The slicer finds the speed ratio that gives the layer the minimum layer time, and no slower. A short layer also gets the fan at its maximum.

## 7. Run it fast, with little memory (`src/engine.zig`, `src/parallel.zig`)

Stage 3 makes each layer from the mesh alone, so all layers can run at the same time on different threads. Stage 5 needs the outlines of the layers above and below, so it starts after stage 3 ends. Then it also runs on all threads.

The outlines are small, so the engine keeps all of them. The layer plans are large, so the engine keeps only a ring of a few of them. The threads plan the next layers while the G-code of the earlier layers goes out, and they also write the text of the G-code. The G-code goes out in layer order, as it is made.

An app slices again after each change of a setting. Most changes do not change the outlines (for example, the infill or the wall count), so the new slice takes the outlines of the old slice. Each layer also keeps the results of its slow steps with the values that made them (a "memo"), and the new slice uses each result that is still good.

## Try it

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zslice demo demo.stl
./zig-out/bin/zslice preview demo.stl --layer 28 -o layer28.svg
./zig-out/bin/zslice slice demo.stl -o demo.gcode
```

Open `layer28.svg` in a browser. Orange is the outer wall, yellow the inner wall, blue the skin, and green the sparse infill. Gray dashes show the travel moves.
