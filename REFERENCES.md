# References and licenses

zslice is licensed under AGPL-3.0-or-later. See `LICENSE`.

This file lists each source that zslice uses. See the rules in `AGENTS.md`.

## Code in the binaries

The zslice library, command line tool, and wasm module contain code from these projects. Their license texts are in `licenses/`.

| Project | License | Text | Notes |
|---|---|---|---|
| Zig standard library | MIT | `licenses/zig-std-MIT.txt` | The compiler links the parts that zslice calls into each binary. |
| musl libc (math functions in the Zig standard library, for example `atan2` and `acos`) | MIT | `licenses/musl-MIT.txt` | The Zig standard library has ports of musl math functions. The port keeps the musl notice. |
| Go (`std.fmt.parseFloat` in the Zig standard library is derived from Go `strconv/atof.go`) | BSD-3-Clause | `licenses/go-BSD-3-Clause.txt` | zslice parses numbers in ASCII STL files and in settings with `parseFloat`. |
| ARM optimized-routines (`std.math.acos` in the Zig standard library) | MIT (dual MIT OR Apache-2.0 WITH LLVM-exception; zslice uses the MIT terms) | `licenses/arm-optimized-routines.txt` | `src/offset.zig` uses `acos` for round joins. |
| Zig compiler_rt (parts ported from LLVM compiler-rt) | MIT, and Apache-2.0 WITH LLVM-exception | `licenses/zig-std-MIT.txt` | The LLVM exception removes the notice requirement for compiled code. The entry is here for completeness. |

zslice copies no code from other projects.

## Libraries that the app shells link

The shells link these libraries as shared libraries from the system. Their code is not in a zslice binary. The Licenses window of each shell lists them.

| Shell | Library | License |
|---|---|---|
| Linux (`linux/`) | GTK 4 | LGPL-2.1-or-later |
| Linux (`linux/`) | GLib | LGPL-2.1-or-later |
| Linux (`linux/`) | cairo | LGPL-2.1-only OR MPL-1.1 |

## Algorithms, formats, and conventions

These sources gave methods or formats. zslice does not copy their code. Each zslice file that uses a source names it in its header comment.

| Source | License | Used in | How zslice uses it |
|---|---|---|---|
| Clipper2, Angus Johnson. https://github.com/AngusJohnson/Clipper2 | Boost Software License 1.0 | `src/offset.zig` | The offset method: move each edge along its normal, join at the vertices (miter, round, or a loop through the original vertex at a closing corner), then a union with the "positive" fill rule. zslice has its own implementation. |
| Bala R. Vatti, "A generic solution to polygon clipping", Communications of the ACM 35(7), 1992 | Paper | `src/clip.zig` | Named as the sweep-line method that Clipper uses. zslice uses a different method (planar arrangement and winding numbers). |
| Winding numbers and fill rules (even-odd, non-zero, positive) | General computational geometry; the names follow the SVG and PostScript fill rules and Clipper2 | `src/clip.zig`, `src/offset.zig` | The rule that decides if a point is inside a polygon set. |
| Shoelace formula for polygon area | Mathematics | `src/geom.zig` | The signed area of a polygon. |
| John Amanatides and Andrew Woo, "A Fast Voxel Traversal Algorithm for Ray Tracing", Eurographics 1987 | Paper | `src/clip.zig` | The walk of an edge through the cells of the uniform grid that finds candidate crossings. |
| Doubly connected edge list (half-edge structure), as in de Berg et al., "Computational Geometry: Algorithms and Applications" | Textbook method | `src/clip.zig` | The faces of the arrangement, walked to find the winding numbers. |
| Cura profile files (Ultimaker Cura, https://github.com/Ultimaker/Cura): `.def.json` definitions with `inherits` and `overrides`, `.inst.cfg` files with a `[values]` section, `.xml.fdm_material` materials, and the setting names | LGPL-3.0 (Cura; the formats and the names, not code) | `src/import_cura.zig` | The import of a Cura profile stack. |
| TOML v1.0.0, https://toml.io/en/v1.0.0 | MIT (the specification) | `src/toml.zig`, `src/profile.zig` | The profile file format. zslice parses a subset. |
| STL file format, 3D Systems. Description: https://en.wikipedia.org/wiki/STL_(file_format) | File format | `src/mesh.zig` | The binary and ASCII STL loader and the binary STL writer. |
| Integer coordinates in micrometers, as in CuraEngine (https://github.com/Ultimaker/CuraEngine) | AGPL-3.0 | `src/geom.zig` | The coordinate unit. CuraEngine uses 1 unit = 1 micrometer (`include/types/Coord_t.h`). zslice uses the same unit. No code is copied. |
| CuraEngine G-code comments: `;FLAVOR:`, `;LAYER_COUNT:`, `;LAYER:n`, `;TYPE:WALL-OUTER`, `WALL-INNER`, `SKIN`, `FILL` | AGPL-3.0 (the convention, not code) | `src/gcode.zig` | The comment names, so that G-code viewers and printdeck (`deck/internal/gcode/gcode.go`) find the layers and features. |
| Scanline polygon fill (sort the edge crossings on each line, fill between them by winding number) | General computer graphics technique | `src/infill.zig` | The line infill. |
| Greedy nearest-neighbor path order | General technique | `src/layer.zig` | The order of the paths in a layer. |
| Mathematical morphology "opening" (erode, then dilate) | General technique | `src/offset.zig`, `src/layer.zig` | Removes skin areas that are too thin to print. |
| Slab index (bucket edges into equal bands of one axis, then cast a ray only against one band) | General technique | `src/clip.zig` | Finds the edges that a winding ray crosses. |
| Compressed sparse row (CSR) layout: one array of items and one array of start offsets | General technique | `src/clip.zig`, `src/slicer.zig` | The slab index and the per-layer face index. |
| Cut plane at the middle of each layer | General slicing practice | `src/slicer.zig` | The z where the mesh is cut for each layer. |
| Joining cut segments by the ID of the mesh edge that they cross | General mesh technique | `src/slicer.zig` | Makes closed loops from the segments of a layer without a coordinate tolerance. |
| Polyline simplification with an anchor point and a distance bound | General technique | `src/geom.zig` | Removes points that change a shape by less than the tolerance. |
| PrusaSlicer G-code comment name `;TYPE:Ironing` (https://github.com/prusa3d/PrusaSlicer) | AGPL-3.0 (the convention, not code) | `src/gcode.zig` | zslice writes `;TYPE:IRONING`. printdeck reads the name in lowercase. |
| Lookout Marine (same author): a Zig core with a C API and one native shell for each platform | Same author | `src/app.zig`, `linux/` | The structure of the app: the core has the logic, and each shell draws widgets, does file I/O, and moves events to its UI thread. |
| Grid ("normal") support: overhang by angle, columns down to the bed or the part, XY and Z gaps, dense interface layers. As in CuraEngine and PrusaSlicer | General slicer technique (the method, not code) | `src/support.zig` | The support areas of each layer. |
| Iterated snap rounding (repeat the intersection pass on the rounded result) | General computational geometry technique | `src/clip.zig` | Makes the boolean operations robust after crossing points are rounded to the grid. |
