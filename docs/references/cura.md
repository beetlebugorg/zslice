# Cura and CuraEngine

The code, the ideas, and the formats that zslice uses from Ultimaker Cura (LGPL-3.0) and CuraEngine (AGPL-3.0). The printer data of Cura is in [Printer data](printer-data.md).

## Code in the binaries

### CuraEngine Arachne walls

```ref
kind: code
source: CuraEngine
license: AGPL-3.0-or-later
link: https://github.com/Ultimaker/CuraEngine
version: commit 5eff812d2124b2eb93f832e92d33ccdba721135b
files: src/arachne/skeletal.zig, src/arachne/beading.zig, src/arachne/extrusion.zig, src/arachne/walls.zig
area: walls
summary: The Arachne walls are a Zig port of the CuraEngine skeletal trapezoidation, beading strategies, and wall tool paths.
```

CuraEngine, UltiMaker, https://github.com/Ultimaker/CuraEngine, commit `5eff812d2124b2eb93f832e92d33ccdba721135b` (16 November 2026). "Copyright (c) 2026 UltiMaker". "CuraEngine is released under the terms of the AGPLv3 or higher."

**License:** AGPL-3.0-or-later

**Text:** `LICENSE` (the same AGPL-3.0 text as zslice)

**Notes:** The Arachne walls (`project.wall_generator = arachne`) are a port to Zig of these files: `src/arachne/SkeletalTrapezoidation.cpp`, `src/arachne/SkeletalTrapezoidationGraph.cpp`, `src/arachne/STHalfEdge.cpp`, `src/arachne/STHalfEdgeNode.cpp` and their headers in `include/arachne/` (`SkeletalTrapezoidation.h`, `SkeletalTrapezoidationGraph.h`, `SkeletalTrapezoidationEdge.h`, `SkeletalTrapezoidationJoint.h`, `STHalfEdge.h`, `STHalfEdgeNode.h`) to `src/arachne/skeletal.zig`; `src/beading_strategy/BeadingStrategy.cpp`, `DistributedBeadingStrategy.cpp`, `RedistributeBeadingStrategy.cpp`, `WideningBeadingStrategy.cpp`, `OuterWallInsetBeadingStrategy.cpp`, `InnerWallInsetBeadingStrategy.cpp`, `LimitedBeadingStrategy.cpp`, their headers in `include/beading_strategy/`, and `src/utils/beading_strategy_factory.cpp` to `src/arachne/beading.zig`; `src/types/geometry/ExtrusionJunction.cpp`, `ExtrusionLine.cpp`, `PolylineStitcher.cpp`, and the extrusion line parts of `Simplify.cpp` to `src/arachne/extrusion.zig`; `src/WallToolPaths.cpp` and `src/types/geometry/MendedShape.cpp` to `src/arachne/walls.zig`; the parts of `src/utils/voronoi_utils.cpp` that the trapezoidation uses (the parabola steps) to `src/arachne/skeletal.zig`. Each file keeps the copyright line and names its sources.

### CuraEngine seam corner preference

```ref
kind: code
source: CuraEngine
license: AGPL-3.0-or-later
link: https://github.com/Ultimaker/CuraEngine
version: commit 2dcc3ec1be6ac7d0327e1860f25c45f4c18f2bdd
files: src/layer.zig
area: walls
summary: `project.seam_corner` is a Zig port of the CuraEngine choice of the sharpest corner seam: the corner angle, the corner score, and the passes to the back and to the right.
```

CuraEngine, UltiMaker, https://github.com/Ultimaker/CuraEngine, commit `2dcc3ec1be6ac7d0327e1860f25c45f4c18f2bdd` (21 November 2026). "Copyright (c) 2026 UltiMaker". "CuraEngine is released under the terms of the AGPLv3 or higher."

**License:** AGPL-3.0-or-later

**Text:** `LICENSE` (the same AGPL-3.0 text as zslice)

**Notes:** `cornerSeamIndex`, `cornerAngle`, `loopPointAt`, and `filterKeep` in `src/layer.zig` are a port to Zig of `src/types/scoring/CornerScoringCriterion.cpp` (the corner angle at 1 mm on each side and the score of each preference), `src/types/scoring/BestElementFinder.cpp` (the passes that keep the candidates within a score delta), `src/types/scoring/DistanceScoringCriterion.cpp` (the scores for the back and the right), the `SharpestCorner` part of `PathOrderOptimizer::findStartLocation` in `include/PathOrderOptimizer.h`, and `getAngleLeft` of `src/utils/linear_alg_2d.cpp`. The overhang and the texture criteria of CuraEngine are not in the port. The header of `src/layer.zig` keeps the copyright line and names the sources.


## Algorithms, formats, and conventions

### Cura profile files

```ref
kind: format
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/import_cura.zig, src/cura_compare.zig, src/project.zig, src/main.zig
area: files
summary: The import of a Cura profile stack, and the comparison of the zslice settings with it.
```

Cura profile files (Ultimaker Cura, https://github.com/Ultimaker/Cura): `.def.json` definitions with `inherits` and `overrides`, `.inst.cfg` files with a `[values]` section, `.xml.fdm_material` materials, and the setting names

**License:** LGPL-3.0 (Cura; the formats and the names, not code)

**Used in:** `src/import_cura.zig`, `src/cura_compare.zig`

**How zslice uses it:** The import of a Cura profile stack, and the comparison of the zslice settings with it.

### Cura configuration folders

```ref
kind: format
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: linux/src/prefs/cura-stack.c
area: ui
summary: The GTK app finds the stack of the active Cura printer for "Compare with Cura".
```

The Cura configuration folders (Ultimaker Cura, https://github.com/Ultimaker/Cura): `active_machine` in `cura.cfg`, the stack files in `machine_instances/` and `extruders/` with their `[containers]` list (user, quality_changes, intent, quality, material, variant, definition_changes, definition), the container folders of the user and of the resources, and the file names with the URL escapes of Python `quote_plus`

**License:** LGPL-3.0 (Cura; the layout, not code)

**Used in:** `linux/src/prefs/cura-stack.c`

**How zslice uses it:** The GTK app finds the stack of the active Cura printer for "Compare with Cura".

### Lightning infill

```ref
kind: idea
source: Cura
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura/releases/tag/4.12.0
files: src/lightning.zig
area: infill
summary: The idea of the pattern: branches only under the top surfaces, grown from the top down, joined into trees that end at the walls, and shortened on each layer down by an angle.
```

Lightning infill, Ultimaker Cura 4.12 (December 2021), https://github.com/Ultimaker/Cura/releases/tag/4.12.0, implemented in CuraEngine (https://github.com/Ultimaker/CuraEngine)

**License:** AGPL-3.0 (CuraEngine); the method only, no code copied

**Used in:** `src/lightning.zig`

**How zslice uses it:** The idea of the pattern: branches only under the top surfaces, grown from the top down, joined into trees that end at the walls, and shortened on each layer down by an angle. zslice has its own method and code (see the file header).

### Cura tree support (prior art)

```ref
kind: idea
source: Cura
license: LGPL-3.0/AGPL-3.0
files: src/lightning.zig, src/tree_support.zig
area: support
summary: Branch supports that join on the way down.
```

Cura tree support (Ultimaker Cura, 2017 to 2018)

**License:** LGPL-3.0/AGPL-3.0 (prior art; the idea, not code)

**Used in:** `src/lightning.zig`, `src/tree_support.zig`

**How zslice uses it:** Branch supports that join on the way down. Listed as prior art.

### Integer coordinates in micrometers

```ref
kind: idea
source: CuraEngine
license: AGPL-3.0
link: https://github.com/Ultimaker/CuraEngine
files: src/geom.zig
area: slicing
summary: The coordinate unit.
```

Integer coordinates in micrometers, as in CuraEngine (https://github.com/Ultimaker/CuraEngine)

**License:** AGPL-3.0

**Used in:** `src/geom.zig`

**How zslice uses it:** The coordinate unit. CuraEngine uses 1 unit = 1 micrometer (`include/types/Coord_t.h`). zslice uses the same unit. No code is copied.

### CuraEngine G-code comments

```ref
kind: format
source: CuraEngine
license: AGPL-3.0
files: src/gcode.zig
area: gcode
summary: The comment names, so that G-code viewers and printdeck (`deck/internal/gcode/gcode.go`) find the layers and features.
```

CuraEngine G-code comments: `;FLAVOR:`, `;LAYER_COUNT:`, `;LAYER:n`, `;TYPE:WALL-OUTER`, `WALL-INNER`, `SKIN`, `FILL`

**License:** AGPL-3.0 (the convention, not code)

**Used in:** `src/gcode.zig`

**How zslice uses it:** The comment names, so that G-code viewers and printdeck (`deck/internal/gcode/gcode.go`) find the layers and features.

### Cura project 3MF metadata

```ref
kind: format
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/threemf.zig, src/import_cura.zig, src/part_settings.zig
area: files
summary: The reader keeps the metadata of each object.
```

Cura project 3MF files (Ultimaker Cura, https://github.com/Ultimaker/Cura, `plugins/3MFReader` and `plugins/3MFWriter`): the per-object settings in `<metadata name="cura:...">` entries of each object, in the namespace `http://software.ultimaker.com/xml/cura/3mf/2015/10`, the modifier volume flags (`infill_mesh`, `cutting_mesh`, `anti_overhang_mesh`, `support_mesh`), `infill_mesh_order`, and the setting names in `fdmprinter.def.json`

**License:** LGPL-3.0 (Cura; the format and the names, not code)

**Used in:** `src/threemf.zig`, `src/import_cura.zig`, `src/part_settings.zig`

**How zslice uses it:** The reader keeps the metadata of each object. The importer maps the per-object settings to zslice settings.

### Infill meshes

```ref
kind: idea
source: CuraEngine
license: AGPL-3.0
link: https://github.com/Ultimaker/CuraEngine
files: src/layer.zig, src/engine.zig, src/part_settings.zig
area: slicing
summary: The modifier volumes of zslice (`layer.Modifier`).
```

Infill meshes ("Modify settings for infill of other models") and `infill_mesh_order` in CuraEngine (https://github.com/Ultimaker/CuraEngine, `FffPolygonGenerator::processInfillMesh`): the volume does not print; inside it, the infill of the other meshes gets the settings of the volume, and the mesh with the higher order wins an overlap

**License:** AGPL-3.0 (the behavior, not code)

**Used in:** `src/layer.zig`, `src/engine.zig`, `src/part_settings.zig`

**How zslice uses it:** The modifier volumes of zslice (`layer.Modifier`). zslice has its own method: the area of a volume on each layer, cut from the sparse area (and the skin area, if the volume has no top and no bottom thickness) of the part. No code was copied.

### Trihexagon infill and infill line distance

```ref
kind: idea
source: CuraEngine
license: AGPL-3.0
files: src/layer.zig, src/import_cura.zig, src/settings.zig
area: infill
summary: `infill_pattern = trihexagon`, the density from `infill_line_distance`, and `project.infill_angles`. The pattern was compared with the G-code of CuraEngine 5.14 on a box.
```

The trihexagon infill pattern of CuraEngine (`Infill::generateTrihexagonInfill`: three line sets at 0, 60, and 120 degrees, the third moved by half the line distance), the infill line distance of each pattern (`infill_line_distance`: line width / density times 2 for grid, 3 for triangles, trihexagon, and cubic), and the list of infill angles (`infill_angles`, one angle for each layer in turn; Cura measures the angle from the Y axis)

**License:** AGPL-3.0 (the patterns and the conventions, not code)

**Used in:** `src/layer.zig`, `src/import_cura.zig`, `src/settings.zig`

**How zslice uses it:** `infill_pattern = trihexagon`, the density from `infill_line_distance`, and `project.infill_angles`. The pattern was compared with the G-code of CuraEngine 5.14 on a box.

### Interlocking structure

```ref
kind: idea
source: CuraEngine
license: AGPL-3.0
link: https://github.com/Ultimaker/CuraEngine
files: src/paint_split.zig
area: slicing
summary: zslice grows a painted feature down into the part under it as a root, inside the walls of the part (`project.paint_anchor_depth`).
```

The interlocking structure of CuraEngine (`src/interlocking/InterlockingGenerator.cpp`, https://github.com/Ultimaker/CuraEngine): beams of two meshes of two extruders that cross the boundary between them, in layers that change direction, away from the outside

**License:** AGPL-3.0 (read for the choice of the method; no code, no method copied)

**Used in:** `src/paint_split.zig`

**How zslice uses it:** zslice grows a painted feature down into the part under it as a root, inside the walls of the part (`project.paint_anchor_depth`). The beams of Cura go both ways, so the layers of the feature get changes too, and a thin feature has no room for them.

## Settings and behaviors

These entries name the Cura settings and the CuraEngine behaviors that zslice has with the same meaning. zslice has its own code for each.

### Wall thickness and the wall count

```ref
kind: setting
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/settings.zig, src/settings_meta.zig
area: walls
summary: `project.wall_thickness` sets the wall count from a thickness, as `wall_thickness` of Cura.
```

The Cura setting "Wall Thickness" (`wall_thickness` in `fdmprinter.def.json`) gives the wall count as the thickness divided by the line width, rounded. `project.wall_thickness` of zslice has the same meaning (`src/settings.zig`, the resolve step of the wall count).

### Infill Flow, Connect Infill Lines, and Infill Line Directions

```ref
kind: setting
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/settings.zig, src/settings_meta.zig, src/layer.zig
area: infill
summary: `project.infill_flow`, `project.infill_connect`, and `project.infill_angles` have the meaning of the Cura settings of the same names.
```

The Cura settings `infill_material_flow` ("Infill Flow"), `zig_zaggify_infill` ("Connect Infill Lines"), and `infill_angles` ("Infill Line Directions", a list in brackets such as `[45, 135]`) of `fdmprinter.def.json`. zslice has `project.infill_flow`, `project.infill_connect`, and `project.infill_angles` with the same meaning, and reads the list with or without the brackets (`settings.infillAngles`).

### Retract at layer change

```ref
kind: setting
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/settings.zig
area: gcode
summary: `project.retract_layer_change` is off by default, as `retract_at_layer_change` of Cura.
```

The Cura setting `retract_at_layer_change` is off by default. `project.retract_layer_change` of zslice has the same meaning and the same default.

### Monotonic order

```ref
kind: idea
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/layer.zig
area: slicing
summary: The skin lines print in columns with no jump across the part, as the monotonic order of Cura.
```

Cura has "Monotonic Top/Bottom Order" (`skin_monotonic`): each line of the skin prints after the lines next to it on one side. zslice prints the pieces of the scan lines in a similar order (`src/layer.zig`, the skin order). The code is new.

### Arachne wall direction and the inset of a narrow wall

```ref
kind: idea
source: CuraEngine
license: AGPL-3.0-or-later
link: https://github.com/Ultimaker/CuraEngine
version: commit 5eff812d2124b2eb93f832e92d33ccdba721135b
files: src/layer.zig
area: walls
summary: The even Arachne walls turn as in CuraEngine, and a wall line narrower than the nozzle moves in, as in Cura.
```

CuraEngine prints the even walls clockwise around the part, and moves an outer wall narrower than the nozzle inward by half the difference (`wall_0_inset`). The Arachne defaults of zslice follow Cura for the nozzle and the line width (`arachneParams` in `src/layer.zig`).

### Orbit with a right drag

```ref
kind: idea
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/render/view.zig
area: ui
summary: The camera turns with a right drag, around the vertical axis of the world, as in Cura.
```

Cura turns the camera with a right drag, and keeps the bed level. The orbit of zslice (`src/render/view.zig`) has the same controls. Tinkercad and Fusion turn the camera in the same way. The code is new.

### First layer fan ramp

```ref
kind: setting
source: CuraEngine, Cura
license: AGPL-3.0-or-later
link: https://github.com/Ultimaker/CuraEngine
version: commit 2dcc3ec1be6ac7d0327e1860f25c45f4c18f2bdd
files: src/import_cura.zig
area: gcode
summary: The importer turns `cool_fan_full_layer` into `filament.fan_off_layers` and `filament.fan_ramp_layers`, with the line of CuraEngine.
```

CuraEngine `ExtruderPlan::processFanSpeedForFirstLayers` (`src/LayerPlan.cpp`) gives layer k (from 0) below `cool_fan_full_layer` (a layer number from 1, so index n - 1) the speed `cool_fan_speed_0 + (cool_fan_speed_min - cool_fan_speed_0) * k / (n - 1)`. With `cool_fan_speed_0` at 0 (the default), this is the zslice fan off on one layer and a ramp of n - 2 layers. The importer converts it so (`prepareProfile` in `src/import_cura.zig`). The G-code of the Printdeck BLTouch mount (Cura 5.14, `cool_fan_full_layer = 5`) has the same fan speeds on layers 0 to 4.

### Cura settings of the Printdeck BLTouch mount

```ref
kind: setting
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
version: Cura 5.14, fdmprinter.def.json at commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/import_cura.zig, src/settings.zig, src/gcode.zig, src/gcode_vars.zig
area: gcode
summary: The Cura keys of the BLTouch mount profile and their zslice settings: the first layer bed temperature and travel speed, the shrinkage, the fan, the skin order, and the seam corner.
```

The Printdeck BLTouch mount is sliced with CuraEngine from a quality_changes profile (`lulzbot/bltouch/mount/cura/make_profiles.py` of Printdeck). zslice imports each of its keys: `material_bed_temperature_layer_0` (`filament.first_layer_bed_temp`, new; CuraEngine `GCodeExport` heats the bed to it and sets `material_bed_temperature` on layer 1), `speed_travel_layer_0` (`machine.first_layer_travel_speed`, new; `PathConfigStorage`), `material_shrinkage_percentage_xy` and `_z` (`filament.shrinkage_xy` and `shrinkage_z`; CuraEngine `MeshGroup::scaleFromBottom`), `cool_fan_speed_min` and `cool_fan_full_layer` (see "First layer fan ramp"), `retract_at_layer_change`, `skin_monotonic` (`project.skin_pattern = monotonic`), `z_seam_corner` (`project.seam_corner`, new; see "CuraEngine seam corner preference"), `speed_wall` (the importer gives it to `speed_wall_0` and `speed_wall_x`, as the Cura formulas do), and `material_standby_temperature`. `layer_0_z_overlap` and `raft_airgap` have an effect only with a raft, which zslice does not have.

### Support speeds

```ref
kind: setting
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
version: fdmprinter.def.json at commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/settings.zig, src/import_cura.zig
area: support
summary: `project.support_speed` and `project.support_interface_speed` have the meaning of `speed_support_infill` and `speed_support_interface`; the importer fills them in with the Cura formulas.
```

In `fdmprinter.def.json`, `speed_support` is `speed_print`, `speed_support_infill` is `speed_support`, and `speed_support_interface` is `speed_support / 1.5`. The importer gives a profile these values when it does not set them (`prepareProfile` in `src/import_cura.zig`). In zslice, 0 keeps the infill speed and the skin speed, the speeds of the support before these settings.

### Wall order and an extra wall on alternate layers

```ref
kind: setting
source: Cura, OrcaSlicer
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura
version: Cura commit 1a221ec29a86960d16a412940becc1f63534c41f; OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/settings.zig, src/layer.zig
area: walls
summary: `project.wall_order` has the meaning of `inset_direction` (Cura) and `wall_sequence` (OrcaSlicer), and `project.alternate_extra_wall` of `alternate_extra_perimeter` (Cura) and `alternate_extra_wall` (OrcaSlicer).
```

Cura and OrcaSlicer let the user print the outer wall first, for a more exact outer surface, or last, for better overhangs. Both can add one wall on every other layer, so that the infill lies between the extra walls. zslice has the two orders (no inner-outer-inner order) and the extra wall on the odd layers. The settings only; no code is copied.

### Fuzzy skin

```ref
kind: idea
source: Cura, OrcaSlicer
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura
version: Cura commit 1a221ec29a86960d16a412940becc1f63534c41f; OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/layer.zig, src/settings.zig
area: walls
summary: `project.fuzzy_skin`, `project.fuzzy_skin_thickness`, and `project.fuzzy_skin_point_distance` have the meaning of the fuzzy skin settings of Cura (`magic_fuzzy_skin_*`) and OrcaSlicer (`fuzzy_skin*`).
```

Cura and OrcaSlicer replace the points of the outer wall with random points a random distance apart, each moved a random distance across the wall. zslice does the same in `fuzzWalls`, with the random numbers from the layer and the path, so a slice gives the same points each time. The seam point stays. The idea and the settings only; no code is copied.

### Spiral vase mode

```ref
kind: idea
source: Cura, OrcaSlicer
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura
version: Cura commit 1a221ec29a86960d16a412940becc1f63534c41f; OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/layer.zig, src/gcode.zig, src/settings.zig
area: walls
summary: `project.spiral_vase` has the meaning of `magic_spiralize` (Cura) and `spiral_mode` (OrcaSlicer): after the bottom layers, one outer wall that rises along its length.
```

Cura and OrcaSlicer print a vase as one spiral: after the bottom layers, the outer wall of each layer rises from the layer below to its own height along its length, so there is no layer change and no seam. zslice does the same in `layer.spiralize`, with the z of each point as a path that is not planar, and the bead of the first spiral layer grows from zero. The idea and the setting only; no code is copied.

### Coasting

```ref
kind: setting
source: Cura
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura
version: commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/gcode.zig, src/settings.zig
area: gcode
summary: `project.coasting_volume` and `project.coasting_speed` have the meaning of `coasting_volume` and `coasting_speed` of Cura.
```

Cura replaces the last part of a path, by its volume of plastic, with a move that does not extrude, at a ratio of the speed. zslice does the same in `Emitter.coastPath`. A path coasts if it has twice the coasting volume, in place of the `coasting_min_volume` of Cura. The settings and the idea only; no code is copied.
