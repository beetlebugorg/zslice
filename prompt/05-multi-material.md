# 05. Multi-material: filaments, paint, labels, prime towers, and the flush

## Goal

Print a plate with more than one filament: a filament for each part, each layer range, each body, the support, each painted face, and each label. Change the filament with a pause or a tool change. Flush the old color into hidden lines and a prime tower. Support printers with two nozzles (Bambu Lab H2D and X2D).

## Read first

- [Print in colors](../docs/user/filaments.md) and [Labels on a part](../docs/user/labels.md).
- [Labels](../docs/embedding/labels.md) for the JSON of a label.
- [Bambu Studio](../docs/references/bambu-studio.md), [PrusaSlicer](../docs/references/prusaslicer.md), [Fonts](../docs/references/fonts.md), [Papers and algorithms](../docs/references/papers-and-algorithms.md) (marching squares, the jump flood).
- The headers of `src/filaments.zig`, `src/paint.zig`, `src/paint_split.zig`, `src/field.zig`, `src/label.zig`, `src/font.zig`, `src/paint_body.zig`.

## Build

1. `src/filaments.zig` and `src/app/filament_slots.zig`: slot 1 is the filament of the settings. Slots 2 and on are full filaments (material, color, temperatures). A part or a layer range prints with the slot of `project.filament`.
2. `machine.filament_change`: `pause` (default: M600, or PAUSE on Klipper) or `tool` (Tn for slot n + 1, for an AMS or an MMU). A Bambu Lab printer flushes into its chute in `machine.change_gcode`.
3. The flush volume of a change: `machine.flush_volume` (default 140) times `1 + 3 * max(0, L(to) - L(from)) + |to - from|`, where L is the luma (0 to 1) and `|to - from|` the RGB distance (0 to 1). Then times `project.flush_multiplier`. Black to white flushes about 5 times the base.
4. The order of the filaments of a layer: try each order (up to 8 filaments), and pick the least flush after the hidden lines take their part. Count the time of each change, so the order never adds a change to save a little plastic.
5. Flush into hidden lines (`project.flush_into_hidden`): after a change, the new filament prints its infill and support body first. A change between two kinds of material flushes into the support body only.
6. Prime towers (`project.prime_tower`, default on, only with `filament_change = tool`): one tower for each family of materials that bond (`project.prime_tower_split`, default on), sized from the purge of each layer, `prime_tower_width` 20 mm. With `prime_tower_x` and `prime_tower_y` at -1, the tower goes to the back of the bed. Draw the towers in the 3D view.
7. Support in its own filament: `project.support_filament` and `project.support_interface_filament`.
8. Paint (`src/paint.zig`): a state for each triangle, or a tree of smaller triangles. Use the nibble form of PrusaSlicer (`slic3rpe:mmu_segmentation`) and Bambu Studio (`paint_color`) in 3MF files, so painted files open with their paint and save the same form. A part with no paint has no memory for it. A brush splits only the triangles on its edge.
9. The paint split (`src/paint_split.zig`, `src/field.zig`): each point of the outline gets the filament of the nearest painted source, from a distance field on a grid of half a line width. Deeper than about 2 mm from the sources, a point is of the filament of the part. A painted top prints its color in its top layers. Each filament of the part then slices as its own job.
10. Roots of painted features: a feature that stands on the part grows into it by `project.paint_anchor_depth` (default 1 mm; 0 is off), inside the walls, in place of the infill. `project.paint_anchor_shape`: footprint or core. A feature on the bed or over air gets no root.
11. A body on some layers (`src/paint_body.zig`): a drag over layers from a line of one body paints only that body.
12. Labels (`src/label.zig`, `src/font.zig`, the Inter font): text, lines, bars, rings, dial ticks, and free lines on the surface of a part, in a filament of their own. A label is a 2D shape in a plane with a frame (origin, normal, right) in the frame of the file mesh, so a move of the part keeps the label on its face. The region of a label wins over the paint and the roots.
13. Two nozzles: each filament has a nozzle (`filament.nozzle`: main or 2nd). Check the reach of each nozzle. Keep the prime tower in the reach of both nozzles of the H2D.

## Numbers and rules that matter

- A label stroke of two lines (text about 4 mm tall with a 0.4 mm nozzle) prints clean. One line (about 2 mm) prints rough. The default depth is one line.
- A side label adds about one change for each layer it covers. "VOLUME" 5 mm tall at 0.2 mm layers is 26 changes, about 17 minutes. A top label adds about 3. The card warns when a side label adds more than 10 changes.
- Each layer of a root can add a change. A layer that already has both filaments gets no new change.
- A print of one filament gives the same G-code as before multi-material existed.

## Lessons

- **The paint split used polygons first.** It grew the painted seeds in steps of one line width, with an offset and three booleans for each step and each filament. A brushed 3DBenchy hull needed 4 to 22 s and 3 to 9 GB. The distance field does the same split in 90 ms on 8 threads. A part with no paint has the same G-code.
- Stop the paint split of a slice on a cancel.
- Keep the filament of each part of a Bambu Studio 3MF.
- Keep labels in the 3MF file, the snapshots, and the history.
- Keep the material and the color in their Bambu config lines.

## Acceptance checks

1. A plate with two parts of two filaments changes the filament where the slot changes, with M600 on Marlin and PAUSE on Klipper.
2. A painted 3MF from PrusaSlicer or Bambu Studio opens with its paint, and a save writes the same paint text.
3. A brushed 3DBenchy hull splits in well under a second (90 ms on 8 threads at the time of writing).
4. A label on a top face prints in its top layers only.
5. Black, red, and white on one layer print black, then red, then white.
6. A part on the second nozzle out of its reach shows in the Check.
