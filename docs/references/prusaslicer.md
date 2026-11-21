# PrusaSlicer and Slic3r

The ideas and the formats that zslice uses from PrusaSlicer and Slic3r (AGPL-3.0). zslice copies no code of them. The printer data of PrusaSlicer is in [Printer data](printer-data.md).

## Algorithms, formats, and conventions

### Support Cubic infill (prior art)

```ref
kind: idea
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
files: src/lightning.zig
area: infill
summary: Infill that is dense only near the top surfaces, where they need support.
```

PrusaSlicer 2.3 "Support Cubic" infill (2020 to 2021), https://github.com/prusa3d/PrusaSlicer

**License:** AGPL-3.0 (prior art; the idea, not code)

**Used in:** `src/lightning.zig`

**How zslice uses it:** Infill that is dense only near the top surfaces, where they need support. Listed as prior art.

### Slic3r flow model

```ref
kind: idea
source: Slic3r, PrusaSlicer
license: AGPL-3.0
files: src/flow.zig
area: gcode
summary: The plastic volume for each line, and the bead width in the 3D view.
```

The Slic3r flow model: the cross section of an extruded bead is a rectangle with half circles on the sides (Slic3r and PrusaSlicer, `Flow.cpp`, and the Slic3r manual)

**License:** AGPL-3.0 (the model, not code)

**Used in:** `src/flow.zig`

**How zslice uses it:** The plastic volume for each line, and the bead width in the 3D view.

### Ironing G-code comment

```ref
kind: format
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
files: src/gcode.zig
area: gcode
summary: zslice writes `;TYPE:IRONING`. printdeck reads the name in lowercase.
```

PrusaSlicer G-code comment name `;TYPE:Ironing` (https://github.com/prusa3d/PrusaSlicer)

**License:** AGPL-3.0 (the convention, not code)

**Used in:** `src/gcode.zig`

**How zslice uses it:** zslice writes `;TYPE:IRONING`. printdeck reads the name in lowercase.

### Paint in 3MF files

```ref
kind: format
source: PrusaSlicer, Bambu Studio
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: tag version_2.9.7
files: src/paint.zig, src/paint_body.zig, src/threemf.zig
area: files
summary: zslice reads and writes the triangle paint of PrusaSlicer and Bambu Studio 3MF files.
```

The paint of a mesh in a 3MF file: the triangle attribute `slic3rpe:mmu_segmentation` of PrusaSlicer and `paint_color` of Bambu Studio, a tree of split triangles as hex nibbles (the split sides, the special side, the children last first, and the states with their extension nibbles), as `TriangleSelector::serialize` and `FacetsAnnotation::get_triangle_as_string` of PrusaSlicer write it (https://github.com/prusa3d/PrusaSlicer, tag `version_2.9.7`, `src/libslic3r/TriangleSelector.cpp`, `src/libslic3r/Model.cpp`); the filaments of a project: `Metadata/model_settings.config` and `Metadata/project_settings.config` of Bambu Studio, `Metadata/Slic3r_PE_model.config` and `Metadata/Slic3r_PE.config` of PrusaSlicer

**License:** AGPL-3.0 (the format, no code)

**Used in:** `src/paint.zig`, `src/paint_body.zig`, `src/threemf.zig`

**How zslice uses it:** zslice reads and writes the paint of each triangle in this form, so a painted model from MakerWorld or Printables opens with its colors, and a file of zslice opens in PrusaSlicer and Bambu Studio with its paint. The filament of a body of some layers (`src/paint_body.zig`) is paint in the same form. It reads the filament of each object and part, and the colors of the filaments of the project.

### Multi-material segmentation

```ref
kind: idea
source: PrusaSlicer
license: AGPL-3.0
version: tag version_2.9.7
files: src/paint_split.zig, src/field.zig, src/plate_job.zig, src/engine.zig
area: slicing
summary: zslice gives each point of a layer the color of the nearest colored edge with a distance field on a grid (PrusaSlicer uses a Voronoi diagram), and slices each filament of a painted part as its own job.
```

The multi-material segmentation of PrusaSlicer (`src/libslic3r/MultiMaterialSegmentation.cpp`, tag `version_2.9.7`): each layer splits by the colors of the painted triangles that cross it, a painted top or bottom colors the layers within the shell thickness, and each color region slices with its own walls and infill

**License:** AGPL-3.0 (the method, no code)

**Used in:** `src/paint_split.zig`, `src/plate_job.zig`, `src/engine.zig`

**How zslice uses it:** zslice gives each point of a layer the color of the nearest colored edge with a distance field on a grid (PrusaSlicer uses a Voronoi diagram), and slices each filament of a painted part as its own job.

### Text and SVG emboss

```ref
kind: idea
source: PrusaSlicer, Bambu Studio, OrcaSlicer
license: AGPL-3.0
link: https://help.prusa3d.com/article/text-tool_399460
files: src/label.zig, src/paint_split.zig, src/plate_job.zig
area: slicing
summary: A label of zslice stays a 2D shape (text, ticks, bars, an SVG picture) in the project, printed as ink, raised, or cut.
```

The text and SVG emboss tools of PrusaSlicer 2.6 and later (https://help.prusa3d.com/article/text-tool_399460, https://help.prusa3d.com/article/svg-embossing-tool_686167), the 3D text tool of Bambu Studio and OrcaSlicer (https://wiki.bambulab.com/en/software/bambu-studio/3d-text), and the setting `mmu_segmented_region_max_width` of PrusaSlicer and OrcaSlicer (https://www.orcaslicer.com/wiki/print_settings/multimaterial/multimaterial_settings_advanced): a text or a shape on the surface of a part as a modifier with a filament, and a painted region cut to a band from the surface, with thin slivers joined to the next region

**License:** AGPL-3.0 (the method, no code)

**Used in:** `src/label.zig`, `src/paint_split.zig`, `src/plate_job.zig`

**How zslice uses it:** A label of zslice stays a 2D shape (text, ticks, bars, an SVG picture) in the project. Each layer gets the prism of the shape along its normal, cut to the band of the depth of the label from the outline of the layer, with a clean-up of strokes and gaps narrower than the narrowest line. The tools of PrusaSlicer make a text or an SVG a part (raised) or a negative volume (cut) as well as a modifier. zslice has the same three choices as a mode of the label: ink, raised, and cut. A raised or cut label changes the outlines of the layers in the band of its relief, with no new mesh (a raised label on a top face adds walls to the mesh).

### Wipe tower

```ref
kind: idea
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: tag version_2.9.7
files: src/gcode.zig, src/plate_job.zig
area: gcode
summary: The purge of a tool change in rows inside the perimeter of the tower, a sparse layer on each layer with no change so the tower is at the z of the nozzle, and the depth of the tower from the most purge of one layer.
```

The wipe tower of PrusaSlicer (`src/libslic3r/GCode/WipeTower.cpp`, tag `version_2.9.7`): each tool change purges in rows of lines (a zigzag) inside the perimeter of the tower, at the z of the layer; each layer up to the last change gets the perimeter and a sparse infill ("finish_layer"), so the tower is as high as the nozzle at each change; the depth of the tower comes from the most purge of one layer. With "no sparse layers", the nozzle goes down to the top of the tower instead.

**License:** AGPL-3.0 (the method, no code)

**Used in:** `src/gcode.zig` (`Emitter.towerPurge`, `Emitter.towerFinish`, `Tower`), `src/plate_job.zig` (`PlateJob.towers`)

**How zslice uses it:** The rows inside the loop, a layer of the tower on each layer up to its last change, and the size of the tower from the most purge of one layer. zslice lowers the nozzle to the top of the tower only as a fallback, for a tower that missed a layer.

## G-code and settings

### G-code thumbnails

```ref
kind: format
source: PrusaSlicer, Klipper
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
files: src/render/cpu.zig, src/settings.zig
area: gcode
summary: The thumbnail block of a G-code file, in the form of PrusaSlicer, which the screens of printers read.
```

PrusaSlicer writes pictures of the print at the top of the G-code as `; thumbnail begin <w>x<h> <size>`, base64 PNG lines, and `; thumbnail end`. Prusa printers and Klipper with Mainsail or Fluidd read them. `machine.thumbnails` and `src/render/cpu.zig` write this block. The format only; no code is copied.

### The box of the first layer in a start G-code

```ref
kind: format
source: PrusaSlicer, OrcaSlicer
license: AGPL-3.0
link: https://help.prusa3d.com/article/list-of-placeholders_205643
files: src/engine.zig, src/gcode_vars.zig
area: gcode
summary: The start G-code variables `first_layer_print_min` of PrusaSlicer and `adaptive_bed_mesh_min` of OrcaSlicer.
```

PrusaSlicer has `first_layer_print_min` and `first_layer_print_max`, and OrcaSlicer has `adaptive_bed_mesh_min` and `adaptive_bed_mesh_max`: the box of the first layer, for a bed mesh of that area. zslice computes the box when a start G-code uses one of them (`usesFirstLayerBox` in `src/engine.zig`).

### PrusaSlicer config files and their keys

```ref
kind: format
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: PrusaSlicer 2.8 (src/libslic3r/PrintConfig.cpp)
files: src/import_profile.zig
area: files
summary: The import of a PrusaSlicer config file, a config bundle, and the config of a 3MF project, with the meaning of each key that zslice maps.
```

PrusaSlicer saves its settings as `key = value` lines: an exported config (`.ini`), a config bundle with a section for each preset (`[print:Name]`) and a `[presets]` section, the end of a G-code file (`; key = value`), and `Metadata/Slic3r_PE.config` in a 3MF project. A text escapes a line break as `\n`. A value for each extruder is a list with commas. Some speeds are percentages of other speeds (`external_perimeter_speed` of `perimeter_speed`, `solid_infill_speed` of `infill_speed`), and a line width in percent is of the layer height. `support_material_threshold` is an angle from the horizontal plane. zslice reads these files and maps the keys to its settings. The format and the names only; no code is copied.

### Complete individual objects and the extruder clearance

```ref
kind: setting
source: PrusaSlicer, OrcaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: PrusaSlicer 2.9.2 (src/libslic3r/PrintConfig.cpp)
files: src/settings.zig, src/plate_job.zig, src/gcode.zig, src/app/checks.zig, src/app.zig
area: plate
summary: `project.print_sequence`, `machine.clearance_radius`, and `machine.clearance_height` have the meaning of `complete_objects`, `extruder_clearance_radius`, and `extruder_clearance_height`.
```

PrusaSlicer prints one object at a time with `complete_objects`. Its head model is a cylinder around the nozzle (`extruder_clearance_radius`, default 20 mm) and a height to the gantry (`extruder_clearance_height`, default 20 mm): the objects keep the radius from each other, and only the last object can be higher. OrcaSlicer has the same model with `print_sequence = by object`, `extruder_clearance_radius` (default 40 mm), and `extruder_clearance_height_to_rod` (default 40 mm). zslice uses the same model, with the defaults of OrcaSlicer. Its levels, its lift over the printed parts, and its check are its own; no code is copied.

### The shape of an "open in slicer" link

```ref
kind: format
source: PrusaSlicer
license: AGPL-3.0
link: https://help.prusa3d.com/article/opening-models-in-prusaslicer-from-supported-websites_399198
version: PrusaSlicer 2.6.0 (the downloader)
files: windows/src/net/zs_open_link.cpp, windows/src/prefs/zs_app_shell.cpp, windows/src/app/MainWindow.Open.cpp
area: files
summary: `zslice://open?file=<URL>` has the shape of the `prusaslicer://open?file=<URL>` links that model sites use.
```

Model sites such as Printables open a model in a slicer with a link of the form `prusaslicer://open?file=<URL>`. zslice takes only that shape, with its own scheme. Its rules for a link are its own: it asks first, takes https from public hosts, checks each redirect, limits the size, refuses a zslice project, and never starts a print. No code is copied.
