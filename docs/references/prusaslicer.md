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
