# 05. Multi-material: filaments, paint, labels, prime towers, and the flush

## Goal

Print a plate with more than one filament: a filament for each part, each layer range, each body, the support, each painted face, and each label. Change the filament with a pause or a tool change. Flush the old color into hidden lines and a prime tower. Support printers with two nozzles (Bambu Lab H2D and X2D), and tool changers with up to 16 nozzles (Prusa XL, CORE One INDX).

## Read first

- [Print in colors](../docs/user/filaments.md) and [Labels on a part](../docs/user/labels.md).
- [Labels](../docs/embedding/labels.md) for the JSON of a label.
- [Bambu Studio](../docs/references/bambu-studio.md), [PrusaSlicer](../docs/references/prusaslicer.md), [Fonts](../docs/references/fonts.md), [Papers and algorithms](../docs/references/papers-and-algorithms.md) (marching squares, the jump flood).
- The headers of `src/filaments.zig`, `src/paint.zig`, `src/paint_split.zig`, `src/field.zig`, `src/label.zig`, `src/font.zig`, `src/body_region.zig`.

## Build

1. `src/filaments.zig` and `src/app/filament_slots.zig`: slot 1 is the filament of the settings. Slots 2 and on are full filaments (material, color, temperatures). A part or a layer range prints with the slot of `project.filament`.
2. `machine.filament_change`: `pause` (default: M600, or PAUSE on Klipper) or `tool` (Tn for slot n + 1, for an AMS or an MMU). A Bambu Lab printer flushes into its chute in `machine.change_gcode`.
3. The flush volume of a change: `machine.flush_volume` (default 140) times `1 + 3 * max(0, L(to) - L(from)) + |to - from|`, where L is the luma (0 to 1) and `|to - from|` the RGB distance (0 to 1). Then times `project.flush_multiplier`. Black to white flushes about 5 times the base.
4. The order of the filaments of a layer: try each order (up to 8 filaments), and pick the least flush after the hidden lines take their part. Count the time of each change, so the order never adds a change to save a little plastic.
5. Flush into hidden lines (`project.flush_into_hidden`): after a change, the new filament prints its infill and support body first. A change between two kinds of material flushes into the support body only.
6. Prime towers (`project.prime_tower`, default on, only with `filament_change = tool`): one tower for each family of materials that bond (`project.prime_tower_split`, default on), sized from the purge of each layer, `prime_tower_width` 20 mm. With `prime_tower_x` and `prime_tower_y` at -1, the tower goes to the back of the bed. `src/tower.zig` makes the shape and the lines of each tower layer. The G-code and the view use the same functions, and a test checks that they draw the same lines.
   - Each change goes in this order: the change, the flush, a prime and a wipe on the tower at the z of the layer, then the part.
   - The tower is a rib wall tower, as in Bambu Studio. The wall has `prime_tower_wall_loops` loops (4). Two strips along the diagonals (`prime_tower_rib_width` 8 mm, `prime_tower_extra_rib_length`) stick out at the corners, and the corners get fillets (`prime_tower_fillet_wall`). `prime_tower_rib_wall` off gives a square wall.
   - The rows of each prime go from the inner loop to the inner loop as one zigzag. Each change gets its own block of rows.
   - At the end of a layer, the area of the prime of the next layer gets solid rows. The rest of the inside has sparse lines, close to the walls and further apart toward the center, at the same x on each layer. The first layer is solid.
   - `prime_tower_brim` (3 mm): loops out from the outer loop on the first layer.
   - Each tower grows on each layer up to its last change.
   - A support or infill filament of its own counts up to the top of the support or of the infill.
   - A Bambu Lab printer flushes into its chute (its change G-code). Its tower gets a prime of 45 mm³, as Bambu Studio primes.
7. Support in its own filament: `project.support_filament` and `project.support_interface_filament`.
8. Paint (`src/paint.zig`): a state for each triangle, or a tree of smaller triangles. Use the nibble form of PrusaSlicer (`slic3rpe:mmu_segmentation`) and Bambu Studio (`paint_color`) in 3MF files, so painted files open with their paint and save the same form. A part with no paint has no memory for it. A brush splits only the triangles on its edge.
9. The paint split (`src/paint_split.zig`, `src/field.zig`): each point of the outline gets the filament of the nearest painted source, from a distance field on a grid of half a line width. Deeper than about 2 mm from the sources, a point is of the filament of the part. A painted top prints its color in its top layers. Each filament of the part then slices as its own job.
10. Roots of painted features: a feature that stands on the part grows into it by `project.paint_anchor_depth` (default 1 mm; 0 is off), inside the walls, in place of the infill. `project.paint_anchor_shape`: footprint or core. A feature on the bed or over air gets no root.
11. A body on some layers (`src/body_region.zig`): a drag over layers from a line of one body selects only that body. A filament for it is a pick (see 17).
12. Labels (`src/label.zig`, `src/font.zig`, the Inter font): text, lines, bars, rings, dial ticks, and free lines on the surface of a part, in a filament of their own. A label is a 2D shape in a plane with a frame (origin, normal, right) in the frame of the file mesh, so a move of the part keeps the label on its face. The region of a label wins over the paint and the roots.
    - SVG pictures (`src/svg_path.zig`): an item of kind `svg` has the source of the picture and its height. The reader takes the path data, the basic shapes, the transforms, the fill rules, and simple strokes, as polygons at the tolerance of the labels.
    - Modes: `ink` (the default; its JSON is the same as before), `raised`, or `cut`, with a relief in mm. A cut label removes its shape from the layers within the relief, and the floor of the cut gets skin. A raised label on a side face adds its shape out of the wall. A raised label on a top face adds the walls of a plateau to the mesh. Raised and cut labels work with one filament too.
    - Smart guides (`src/label_snap.zig`, `zs_label_face`, `zs_label_snap`): the face of the part in the plane of the label, with its outline and its holes (round, rectangular, or other). A move snaps to the edges and centers of the other labels in the plane, to equal gaps, to the holes, and to the centers of the face and of the part. A resize also snaps to the size of another label. The core gives the guide lines as JSON.
13. Two nozzles: each filament has a nozzle (`filament.nozzle`: main or 2nd, or T0 to T15 on a printer with more nozzles, part 02). The Check tells a filament on a nozzle that the printer does not have. Check the reach of each nozzle. Keep the prime tower in the reach of both nozzles of the H2D. The second nozzle has its own speed, line width, and retraction (part 02).
    - A switch of the nozzles flushes only when the filament in the new nozzle changed. Bambu Studio flushes 0 there.
    - The idle nozzle goes to 10 °C below its temperature (`M104 T`). `M104 S` sets the print temperature after the `M620.15` cooling of the change G-code.
14. The infill filament (`project.infill_filament`, 0 is the filament of the part): the sparse infill in another filament. A filament of the second nozzle prints it at the line width of that nozzle. With `infill_layers` above 1, only the tall beads use it, and the nozzle changes once for each group of layers. The Check tells when a group is too thick for the nozzle of the infill. The skirt and the tower keep the width of the plate next to a part with wider lines.
15. A part of some layers with its own filament and infill (`src/body_region.zig`). The line card has a Filament row: a chip gives the body of the line on its layer a filament pick (the lines joined to it, `zs_app_paint_body`). The card then offers the layers above and below where the body goes on (`zs_view_connected_layers`). The range card has two filament rows: "This part of the layers" for a lit body, and "Whole layers". With a lit body, each other row has a switch "This part" or "Whole layers". A change for this part makes a region (`zs_app_region_set`): a modifier volume that is a stack of prisms, one for each layer of the body. A region has only the settings of `settings.region_settings` (part 02). The 3MF file and the undo list keep a region.
16. The waste of a print with changes (`zs_app_waste`): the flush out of the print (the chute of a Bambu Lab printer), all lines of the prime towers, and the time of the changes, in grams and seconds. The filament list shows "3 changes, about 2 min · waste 10.3 g (12 %)", with the parts in the tooltip.
17. "This body": when a drag from a line lights one body, the range card has a row "This body" first. A filament chip makes a pick of that body (`zs_app_paint_body`). The pick is a volume of the part, a stack of one prism for each layer, with the metadata key `zslice:layer_pick`. It keeps the holes of the part, and it leaves out the islands that no bead of the body touches. The plate job cuts it at each layer, and each wall, skin, and infill line with at least half of its length in the cut gets the filament (`PlateJob.markPicks`). The lines keep their shape. The newest pick wins over older picks and over paint. The body shows in the color of the filament at once (`zs_view_light_color`). The pick stays after a new slice, and it moves and turns with the part.
18. A filament for one line, or one segment of a line (`zs_app_line_filament`, [Selection and focus](../docs/internals/selection.md#a-filament-for-one-line)). It is an edit of kind 3 of `src/app/edits.zig` with an anchor: the stable part id, a stamp of the shape, and up to 48 points of the line in the frame of the mesh (µm). A slice maps the anchor to the bed with the place of the part. Exactly one line of the same part, feature, and layer must lie within 50 µm of each anchor point and have the same length, or the edit waits and no line changes. A segment cuts its line at the segment ends (a loop opens there). Each piece keeps the width, the height, the region, and the flow. `PlateJob.markLineEdits` adds the filament to the mask of its level, so the tower and the first filaments know it. `LayerPlan.groupByFilament` runs after the edits, so the colored lines of a layer print together.

## Numbers and rules that matter

- A label stroke of two lines (text about 4 mm tall with a 0.4 mm nozzle) prints clean. One line (about 2 mm) prints rough. The default depth is one line.
- A side label adds about one change for each layer it covers. "VOLUME" 5 mm tall at 0.2 mm layers is 26 changes, about 17 minutes. A top label adds about 3. The card warns when a side label adds more than 10 changes.
- Each layer of a root can add a change. A layer that already has both filaments gets no new change.
- A print of one filament gives the same G-code as before multi-material existed. It has no tower, so the tower settings do not change it.
- With no paint and no region, the G-code is the same as before the regions.
- The waste counts the whole tower. The panel showed only the flush first, so it showed less waste than the print had.
- A line in a filament that its layer does not have costs two changes: one to the filament and one back. A second line of the same filament on that layer costs none (`zs_app_line_filament_cost`).
- A cut of a line must keep its length within 5 µm for each point. Else the plan stays as it is, and the edit waits.
- With no filament edit of a line, the G-code is the same as before these edits.

## Lessons

- **The paint split used polygons first.** It grew the painted seeds in steps of one line width, with an offset and three booleans for each step and each filament. A brushed 3DBenchy hull needed 4 to 22 s and 3 to 9 GB. The distance field does the same split in 90 ms on 8 threads. A part with no paint has the same G-code.
- Stop the paint split of a slice on a cancel.
- **Give the ray test of a paint session room at the edges.** A ray on the shared edge of two triangles missed both by rounding, went through the surface, and hit a face behind it. A click on a diagonal then painted the bottom of a box. The edge test of `rayTriangle` now has a room of 1e-5.
- Keep the filament of each part of a Bambu Studio 3MF.
- Keep labels in the 3MF file, the snapshots, and the history.
- Keep the material and the color in their Bambu config lines.
- **Make the new filament ready on the tower before it prints the part.** A change printed the new filament with a prime of 15 mm³ on a weak tower. A tower layer with no change had only its loop and one diagonal, so purge rows bridged up to the full tower width. Towers of more families grew only on the layers with a purge, and the nozzle went down to their top. On the X2D, a switch of the nozzles flushed the full volume into the chute, the idle nozzle stayed at its print temperature, and the new nozzle stayed 10 °C cold after `M620.15`.
- **Give the tower a wall, ribs, a brim, and rows from wall to wall.** The primes lifted from the tower. First a brim and a grid of lines 2 mm apart (in place of 5 mm) came. Then the rows went half a line into the loop at both ends. The primes still lifted off a grid with one loop, so the tower became the rib wall tower of Bambu Studio.
- **Extend the paint of a line with the filament of the pick.** The buttons for the layers above and below painted with the filament of the card. After the slice, the line can report another filament. The extend then painted the wrong filament and erased the paint (GTK).
- **Do not store a pick of some layers as paint.** Paint on the faces at the edge of the range colored the layers next to it, the paint root colored more layers under it, and some lines of the picked body kept the old filament. A pick now changes the filament of the lines of its layers only.
- **Find the outer wall around an inner line.** The body of a line held only the paths inside the box of the line, grown by a wall step. An inner wall whose outer wall goes into a fin or around a boss had no outer wall in its body. Now a closed path of the part around the start line on its layer also starts the walk (`View.connectedPaths`).
- **Start a label resize at its own size.** A corner handle sits on the frame, 4 pixels outside the box of the label, and the resize anchors the box. The first move jumped by the gap. Keep the offset from the pointer to the corner of the box at the press, and take it off each move.
- **Never let a cut drop a line.** A swap of the two ends of a segment as `ends = .{ ends[1], ends[0] }` gave both ends the same place, because Zig writes the first element before it reads the second. The cut of the mirrored wall then made two pieces of one point, and the whole outer wall went out of the layer. Now the swap uses `std.mem.swap`, a match needs a length over 0, and the cut checks the length of its pieces before it changes the plan.
- **Give an edit from undo or a file its state again.** A slice that reuses the move streams applies no edit, so an edit list from undo or a file said "waits" for a line in the print. `Edits.remember` keeps the state of each key after a slice, and `Edits.recall` gives it back.

## Acceptance checks

1. A plate with two parts of two filaments changes the filament where the slot changes, with M600 on Marlin and PAUSE on Klipper.
2. A painted 3MF from PrusaSlicer or Bambu Studio opens with its paint, and a save writes the same paint text.
3. A brushed 3DBenchy hull splits in well under a second (90 ms on 8 threads at the time of writing).
4. A label on a top face prints in its top layers only.
5. Black, red, and white on one layer print black, then red, then white.
6. A part on the second nozzle out of its reach shows in the Check.
7. A raised label in its own filament changes the filament only on the layers of the label.
8. A cut label removes its shape within the relief, and its floor gets skin.
9. On a head with two nozzles, a switch to a nozzle that keeps its filament has no flush.
10. Each tower layer up to the last change has its wall, and the view draws the same lines as the G-code.
11. A filament pick of an inner wall from the line card prints the inner wall and the outer wall around the fin in the new filament (a C API test).
12. A region of a body prints its own infill, and the 3MF file and an undo keep it.
12a. A filament pick of one layer changes all lines of the body on that layer, and zero lines on any other layer. The pick survives a new slice, a move, a turn, and a 3MF reload.
13. A part on an X2D with five spools, in filament 2 and in filament 5 (the external spool on the second nozzle), gives the right bead colors, M620 and T lines, `ams_mapping`, and `slice_info.config`.
12b. The `app: a filament for one line` and `app: a filament for one segment` tests: exactly one path of layer L has filament 2, no path of another layer has it, the G-code has two changes, and the plastic of the part lines stays within 0.01 %. The segment piece has the length of the segment. The edit follows a move, a turn of 90°, a mirror, the file lines, undo, and redo. After a scale it waits and colors no line.
