# Slicer techniques

The techniques that many slicers share. zslice has its own code for each. The entry names the slicers that have the technique.

## Algorithms, formats, and conventions

### Tree support

```ref
kind: idea
source: Cura, PrusaSlicer
license: Idea; no code
files: src/tree_support.zig
area: support
summary: zslice has its own method: tips on a fixed grid, moves limited by the branch angle, joins of nodes that touch, and a radius that gets smaller in narrow spaces.
```

Tree support: the idea of branches that hold overhangs at points and join on the way down, as in Cura "tree support" (LGPL-3.0/AGPL-3.0) and PrusaSlicer "organic support" (AGPL-3.0)

**License:** Idea; no code

**Used in:** `src/tree_support.zig`

**How zslice uses it:** zslice has its own method: tips on a fixed grid, moves limited by the branch angle, joins of nodes that touch, and a radius that gets smaller in narrow spaces. The wider foot of a branch on the bed is the idea of the Cura setting "Branch Diameter on the Build Plate" (`support_tree_bp_diameter`); zslice has its own rule and code. A hollow branch (one wall loop, no lines inside) is the idea of the Cura tree defaults (`support_wall_count` 1, `support_infill_rate` 0). A travel from support to support with no retraction is the idea of the Cura setting "Limit Support Retractions" (`limit_support_retractions`). zslice has its own rules: the solid layers at the foot and under the tip, the join of a circle into a circle that holds it, and the test that the travel crosses no edge of the part.

### Meshmixer tree supports (prior art)

```ref
kind: idea
source: Meshmixer
license: Product
files: src/lightning.zig
area: support
summary: Branch supports that join on the way down.
```

Autodesk Meshmixer tree supports (about 2014)

**License:** Product (prior art)

**Used in:** `src/lightning.zig`

**How zslice uses it:** Branch supports that join on the way down. Listed as prior art.

### Gap fill

```ref
kind: idea
source: PrusaSlicer, Cura
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
files: src/gapfill.zig
area: walls
summary: The idea: a line along the middle of each narrow area that no wall and no skin line covers, with the width of the area.
```

Gap fill: PrusaSlicer "gap fill" (https://github.com/prusa3d/PrusaSlicer) and Cura "fill gaps between walls" (https://github.com/Ultimaker/Cura)

**License:** AGPL-3.0 (PrusaSlicer), LGPL-3.0 (Cura); the idea, not code

**Used in:** `src/gapfill.zig`

**How zslice uses it:** The idea: a line along the middle of each narrow area that no wall and no skin line covers, with the width of the area. zslice finds the areas with its own method and makes the lines with its Arachne port (see "Code in the binaries").

### Combined infill

```ref
kind: idea
source: PrusaSlicer, Cura
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
files: src/layer.zig, src/engine.zig
area: infill
summary: `project.infill_layers`. zslice has its own method.
```

Combined infill: sparse infill printed once every n layers, as one taller bead. PrusaSlicer "Combine infill every n layers" (`infill_every_layers`, https://github.com/prusa3d/PrusaSlicer, from Slic3r) and Cura "Infill Layer Thickness" (`infill_sparse_thickness`, https://github.com/Ultimaker/CuraEngine) have it. Slic3r and PrusaSlicer limit the combined thickness to the nozzle diameter

**License:** AGPL-3.0 (the idea and the limit, not code)

**Used in:** `src/layer.zig`, `src/engine.zig`

**How zslice uses it:** `project.infill_layers`. zslice has its own method: groups from the bottom skin up, the area that is sparse in all layers of a group (with no band under a top), a bead of the group height from the flow model. No code was read or copied.

### Triangle, cubic, and concentric infill

```ref
kind: idea
source: Cura, PrusaSlicer
license: General slicer technique
files: src/layer.zig, src/infill.zig
area: infill
summary: The triangles, cubic, and concentric infill patterns.
```

Triangle, cubic, and concentric infill, as in CuraEngine and PrusaSlicer

**License:** General slicer technique (the patterns, not code)

**Used in:** `src/layer.zig`, `src/infill.zig`

**How zslice uses it:** The triangles, cubic, and concentric infill patterns.

### Order by island

```ref
kind: idea
source: Cura, PrusaSlicer
license: General slicer technique
files: src/layer.zig
area: slicing
summary: The plan prints the walls, skin, infill, and ironing of one island, then goes to the nearest island that is not done.
```

Order by island: all paths of one connected part of a layer before the next part, as the "layer parts" of CuraEngine (AGPL-3.0) and the islands of PrusaSlicer (AGPL-3.0)

**License:** General slicer technique (the order, not code)

**Used in:** `src/layer.zig`

**How zslice uses it:** The plan prints the walls, skin, infill, and ironing of one island, then goes to the nearest island that is not done.

### Cut plane at the middle of each layer

```ref
kind: idea
source: General
license: General slicing practice
files: src/slicer.zig
area: slicing
summary: The z where the mesh is cut for each layer.
```

Cut plane at the middle of each layer

**License:** General slicing practice

**Used in:** `src/slicer.zig`

**How zslice uses it:** The z where the mesh is cut for each layer.

### Ironing

```ref
kind: idea
source: PrusaSlicer, Cura
license: General slicer technique
files: src/layer.zig, src/slope.zig
area: slicing
summary: Planar ironing of top surfaces, and slope ironing over the filled steps, at the height of the filled step at each point.
```

Ironing: a pass of the hot nozzle with a small flow over a top surface, as in PrusaSlicer and Cura

**License:** General slicer technique (the method, not code)

**Used in:** `src/layer.zig`, `src/slope.zig`

**How zslice uses it:** Planar ironing of top surfaces, and slope ironing over the filled steps, at the height of the filled step at each point.

### Grid support

```ref
kind: idea
source: Cura, PrusaSlicer
license: General slicer technique
files: src/support.zig
area: support
summary: The support areas of each layer.
```

Grid ("normal") support: overhang by angle, columns down to the bed or the part, XY and Z gaps, dense interface layers. As in CuraEngine and PrusaSlicer

**License:** General slicer technique (the method, not code)

**Used in:** `src/support.zig`

**How zslice uses it:** The support areas of each layer.

### Auto orientation

```ref
kind: idea
source: Cura, PrusaSlicer
license: General slicer technique
files: src/orient.zig
area: plate
summary: The best orientation of a part for the smart, less-support, and strength placements.
```

Auto orientation of a part for less support (the method of the "Tweaker" auto-rotation of Cura and PrusaSlicer: score candidate directions by overhang area, bed contact, and height)

**License:** General slicer technique (the method, not code)

**Used in:** `src/orient.zig`

**How zslice uses it:** The best orientation of a part for the smart, less-support, and strength placements.

### Polyholes

```ref
kind: idea
source: Chris Palmer (nophead), PrusaSlicer, OrcaSlicer
license: Blog post; AGPL-3.0
link: https://hydraraptor.blogspot.com/2011/02/polyholes.html
version: 2011; OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106 (hole_to_polyhole)
files: src/engine.zig, src/settings.zig
area: slicing
summary: A round hole prints as a regular polygon of max(3, round(2 d)) sides at the radius r / cos(pi / n), so that it prints to size.
```

nophead found that a printed round hole shrinks, and that a polygon with few sides, whose inner circle is the hole, prints to size. PrusaSlicer and OrcaSlicer convert the round holes of a part to polyholes (`hole_to_polyhole`). zslice does it on each layer outline in `engine.polyholes`. The idea and the formula only; no code is copied.
