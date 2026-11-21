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

## Algorithms, formats, and conventions

### Cura profile files

```ref
kind: format
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/import_cura.zig, src/cura_compare.zig
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
