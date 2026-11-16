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
| Khronos Vulkan headers (`vendor/vulkan/include`, version 1.4.350, copied from charttable) | Apache-2.0 (the headers say `SPDX-License-Identifier: Apache-2.0`; the repository also allows MIT) | `licenses/vulkan-headers.txt`, `licenses/apache-2.0.txt` | The types of the Vulkan renderer. The headers have declarations only. zslice loads the Vulkan loader at run time and does not link it. |
| Zig compiler_rt (parts ported from LLVM compiler-rt) | MIT, and Apache-2.0 WITH LLVM-exception | `licenses/zig-std-MIT.txt` | The LLVM exception removes the notice requirement for compiled code. The entry is here for completeness. |

zslice copies no code from other projects.

## Libraries that the app shells link

The shells link these libraries as shared libraries from the system. Their code is not in a zslice binary. The Licenses window of each shell lists them.

| Shell | Library | License |
|---|---|---|
| Linux (`linux/`) | GTK 4 | LGPL-2.1-or-later |
| Linux (`linux/`) | GLib | LGPL-2.1-or-later |
| Linux (`linux/`) | cairo | LGPL-2.1-only OR MPL-1.1 |
| Linux (`linux/`) | libsoup 3 (HTTP for the printer connections) | LGPL-2.0-or-later |
| Linux (`linux/`) | json-glib (the JSON of the printer APIs) | LGPL-2.1-or-later |

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
| OctoPrint REST API, https://docs.octoprint.org/en/master/api/ (`/api/printer`, `/api/printerprofiles`, `/api/job`, `/api/files/local`, the `X-Api-Key` header) | AGPL-3.0 (OctoPrint; the API, not code) | `linux/src/net/printer-link.c` | Read the state of a printer, and send G-code to it. printdeck has the same API. |
| Moonraker API, https://moonraker.readthedocs.io/ (`/printer/objects/query`, `/server/files/upload`) | GPL-3.0 (Moonraker; the API, not code) | `linux/src/net/printer-link.c` | The same, for Klipper printers. |
| printdeck deck API (same author, AGPL-3.0), `deck/internal/octoapi` of printdeck: `/api/plugin/printdeck` (the filament, the spools, the job) | AGPL-3.0 | `linux/src/net/printer-link.c` | The filament in the printer, for "Use the filament in the printer". |
| G-code over a serial port: one command, then wait for the line `ok` (the Marlin and RepRap host protocol), https://reprap.org/wiki/G-code | Protocol | `linux/src/net/printer-link.c` | The USB connection. |
| Tree support: the idea of branches that hold overhangs at points and join on the way down, as in Cura "tree support" (LGPL-3.0/AGPL-3.0) and PrusaSlicer "organic support" (AGPL-3.0) | Idea; no code | `src/tree_support.zig` | zslice has its own method: tips on a fixed grid, moves limited by the branch angle, joins of nodes that touch, and a radius that gets smaller in narrow spaces. |
| STL file format, 3D Systems. Description: https://en.wikipedia.org/wiki/STL_(file_format) | File format | `src/mesh.zig` | The binary and ASCII STL loader and the binary STL writer. |
| Integer coordinates in micrometers, as in CuraEngine (https://github.com/Ultimaker/CuraEngine) | AGPL-3.0 | `src/geom.zig` | The coordinate unit. CuraEngine uses 1 unit = 1 micrometer (`include/types/Coord_t.h`). zslice uses the same unit. No code is copied. |
| CuraEngine G-code comments: `;FLAVOR:`, `;LAYER_COUNT:`, `;LAYER:n`, `;TYPE:WALL-OUTER`, `WALL-INNER`, `SKIN`, `FILL` | AGPL-3.0 (the convention, not code) | `src/gcode.zig` | The comment names, so that G-code viewers and printdeck (`deck/internal/gcode/gcode.go`) find the layers and features. |
| The gyroid, a triply periodic minimal surface (Alan Schoen, 1970), with the common approximation sin x cos y + sin y cos z + sin z cos x = 0. Gyroid infill is in CuraEngine and PrusaSlicer | Mathematics (the surface); general slicer technique (its use as infill) | `src/infill.zig` | The gyroid infill pattern. zslice solves the equation for one coordinate in closed form. |
| The Slic3r flow model: the cross section of an extruded bead is a rectangle with half circles on the sides (Slic3r and PrusaSlicer, `Flow.cpp`, and the Slic3r manual) | AGPL-3.0 (the model, not code) | `src/flow.zig` | The plastic volume for each line, and the bead width in the 3D view. |
| Scanline polygon fill (sort the edge crossings on each line, fill between them by winding number) | General computer graphics technique | `src/infill.zig` | The line infill. |
| Triangle, cubic, and concentric infill, as in CuraEngine and PrusaSlicer | General slicer technique (the patterns, not code) | `src/layer.zig`, `src/infill.zig` | The triangles, cubic, and concentric infill patterns. |
| Greedy nearest-neighbor path order | General technique | `src/layer.zig` | The order of the paths in a layer. |
| Junction deviation, Sonny Jeon, grbl (https://github.com/grbl/grbl, "Improving Grbl: Cornering Algorithm", 2011) | MIT (grbl); the method, not code | `src/motion.zig` | The speed limit at a junction of two moves, from the angle and the corner speed. |
| Klipper kinematics documentation, `docs/Kinematics.md` (https://www.klipper3d.org/Kinematics.html): look-ahead, the square corner velocity, and the minimum cruise ratio | GPL-3.0 (Klipper); the method, not code | `src/motion.zig` | The look-ahead passes, the junction speed from the square corner velocity, the limit of the arc to the middle of each move, the extruder corner speed, and the peak of a group of moves with the minimum cruise ratio. zslice has its own implementation. |
| Order by island: all paths of one connected part of a layer before the next part, as the "layer parts" of CuraEngine (AGPL-3.0) and the islands of PrusaSlicer (AGPL-3.0) | General slicer technique (the order, not code) | `src/layer.zig` | The plan prints the walls, skin, infill, and ironing of one island, then goes to the nearest island that is not done. |
| Mathematical morphology "opening" (erode, then dilate) | General technique | `src/offset.zig`, `src/layer.zig` | Removes skin areas that are too thin to print. |
| Slab index (bucket edges into equal bands of one axis, then cast a ray only against one band) | General technique | `src/clip.zig` | Finds the edges that a winding ray crosses. |
| Compressed sparse row (CSR) layout: one array of items and one array of start offsets | General technique | `src/clip.zig`, `src/slicer.zig` | The slab index and the per-layer face index. |
| Cut plane at the middle of each layer | General slicing practice | `src/slicer.zig` | The z where the mesh is cut for each layer. |
| Joining cut segments by the ID of the mesh edge that they cross | General mesh technique | `src/slicer.zig` | Makes closed loops from the segments of a layer without a coordinate tolerance. |
| Polyline simplification with an anchor point and a distance bound | General technique | `src/geom.zig` | Removes points that change a shape by less than the tolerance. |
| PrusaSlicer G-code comment name `;TYPE:Ironing` (https://github.com/prusa3d/PrusaSlicer) | AGPL-3.0 (the convention, not code) | `src/gcode.zig` | zslice writes `;TYPE:IRONING`. printdeck reads the name in lowercase. |
| Lookout Marine, `linux/src/engine/surface.c` (same author, MIT license) | MIT | `linux/src/ui/native-surface.c` | Adapted: a Wayland subsurface under the GTK window, with an empty input region, for the Vulkan view. |
| charttable, `src/gpu/gpu_vk.zig` (same author, MIT license) | MIT | `src/render/vk.zig` | The structure of the Vulkan backend: run-time loading of the loader, a surface from the shell, a swapchain sized by the host, a UNORM swapchain format, and SPIR-V words copied at comptime. The code is new. |
| Lookout Marine (same author): a Zig core with a C API and one native shell for each platform | Same author | `src/app.zig`, `linux/` | The structure of the app: the core has the logic, and each shell draws widgets, does file I/O, and moves events to its UI thread. |
| Grid ("normal") support: overhang by angle, columns down to the bed or the part, XY and Z gaps, dense interface layers. As in CuraEngine and PrusaSlicer | General slicer technique (the method, not code) | `src/support.zig` | The support areas of each layer. |
| PKWARE, ".ZIP File Format Specification" (APPNOTE.TXT), https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT | Public specification | `src/zipfile.zig` | The zip records (local header, central directory, end record, and the zip64 records and extra field). The header structs and deflate come from the Zig standard library (MIT). |
| 3MF Consortium, "3MF Core Specification" 1.3 and "Production Extension", https://github.com/3MFConsortium/spec_core | BSD-2-Clause (the specification) | `src/threemf.zig` | The 3MF package, the model file, objects, components, build items, transforms, and units. The code is new. |
| Christer Ericson, "Real-Time Collision Detection" (2005), 5.1.5: the closest point on a triangle | General computational geometry technique | `src/plate.zig` (`pointTriangle2`) | The side of a part nearest to a picked point, for "this side on the bed". |
| Auto orientation of a part for less support (the method of the "Tweaker" auto-rotation of Cura and PrusaSlicer: score candidate directions by overhang area, bed contact, and height) | General slicer technique (the method, not code) | `src/orient.zig` | The best orientation of a part for the smart, less-support, and strength placements. |
| Iterated snap rounding (repeat the intersection pass on the rounded result) | General computational geometry technique | `src/clip.zig` | Makes the boolean operations robust after crossing points are rounded to the grid. |
| Least significant digit radix sort (a stable counting sort for each digit, from the low digit to the high digit) | General technique | `src/clip.zig` | Sorts the cell entries of the crossing grid by cell. |
| A. M. Andrew, "Another efficient algorithm for convex hulls in two dimensions", Information Processing Letters 9(5), 1979 (the monotone chain) | Paper | `src/offset.zig` | The convex hull of a loop, for the test that a loop vanishes in an offset. |
| A convex shape with an inscribed circle of radius r has area A >= r P / 2 (P is the perimeter) | Mathematics | `src/offset.zig` | The bound r <= 2 A / P on the largest circle in a convex hull. |
| Uniform grid search for the nearest point, ring by ring | General technique | `src/layer.zig` | Finds the nearest path start in the greedy path order. |
| Memoization: keep a result with the inputs that made it, and use it again for the same inputs | General technique | `src/layer.zig`, `src/engine.zig` | The memo of each layer, which keeps the slow results between slices. |
| Arena allocators kept in a pool and reset between uses | General technique | `src/scratch.zig` | The work memory of the booleans and offsets. |
| Extra beads at Z heights between the layers, to fill the stair of a sloped surface: IBM, US 5,402,351 (filed 1991, expired) | Expired; free to use | `src/slope.zig` | The idea of the slope smoothing pass: after a layer, beads at heights between two layers fill the steps. |
| Hai-Chuan Song, Nicolas Ray, Dmitry Sokolov, Sylvain Lefebvre, "Anti-aliasing for fused filament deposition", Computer-Aided Design 89, 2017 | Paper | `src/slope.zig` | Small Z changes inside a layer, so that the edge of each layer follows the true surface between the layers. zslice uses the idea for its smoothing beads: a Z for each point between two layers. |
| Daniel Ahlers, Florens Wasserfall, Norman Hendrich, Jianwei Zhang, "3D Printing of Nonplanar Layers for Smooth Surface Generation", IEEE CASE 2019 | Paper | `src/slope.zig` | Non-planar moves on top surfaces, and the check of the nozzle shape (a cone) against the printed part. zslice uses a cone on a flat tip, and checks it against the layer that it just printed. |
| Debapriya Chakraborty, B. Aneesh Reddy, A. Roy Choudhury, "Extruder path generation for Curved Layer Fused Deposition Modeling", Computer-Aided Design 40(2), 2008 | Paper | `src/slope.zig` | Extrusion paths with a Z that changes along the path. |
| Volume of a triangle (h * L / 2) and the distance from a point to a segment | Mathematics | `src/slope.zig`, `src/geom.zig` | The plastic of a smoothing bead, and the room for the nozzle. |

## Test tools

zslice runs these programs in its test tools. No code of these programs
is in zslice.

| Program | License | Used in | How zslice uses it |
|---|---|---|---|
| CuraEngine (Ultimaker Cura 5.x), https://github.com/Ultimaker/CuraEngine, and the Cura definition files `fdmprinter.def.json` and `fdmextruder.def.json` | AGPL-3.0 (CuraEngine), LGPL-3.0 (the definitions) | `tools/compare_cura.py` | A test oracle. The script slices each STL file of the corpus with zslice and with CuraEngine, and compares the layer count, the filament, the time estimate, the speed, and the memory. |
