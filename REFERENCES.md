# References and licenses

zslice is licensed under AGPL-3.0-or-later. See `LICENSE`.

This file lists each source that zslice uses. See the rules in `AGENTS.md`.

## Code in the binaries

The zslice library, command line tool, and wasm module contain code from these projects. Their license texts are in `licenses/`.

| Project | License | Text | Notes |
|---|---|---|---|
| Zig standard library | MIT | `licenses/zig-std-MIT.txt` | The compiler links the parts that zslice calls into each binary. |
| musl libc (math functions in the Zig standard library, for example `atan2` and `acos`) | MIT | `licenses/musl-MIT.txt` | The Zig standard library has ports of musl math functions. The port keeps the musl notice. |
| Zig compiler_rt (parts ported from LLVM compiler-rt) | MIT, and Apache-2.0 WITH LLVM-exception | `licenses/zig-std-MIT.txt` | The LLVM exception removes the notice requirement for compiled code. The entry is here for completeness. |

zslice copies no code from other projects.

## Algorithms, formats, and conventions

These sources gave methods or formats. zslice does not copy their code. Each zslice file that uses a source names it in its header comment.

| Source | License | Used in | How zslice uses it |
|---|---|---|---|
| Clipper2, Angus Johnson. https://github.com/AngusJohnson/Clipper2 | Boost Software License 1.0 | `src/offset.zig` | The offset method: move each edge along its normal, join at the vertices (miter, round, or a loop through the original vertex at a closing corner), then a union with the "positive" fill rule. zslice has its own implementation. |
| Bala R. Vatti, "A generic solution to polygon clipping", Communications of the ACM 35(7), 1992 | Paper | `src/clip.zig` | Named as the sweep-line method that Clipper uses. zslice uses a different method (planar arrangement and winding numbers). |
| Winding numbers and fill rules (even-odd, non-zero, positive) | General computational geometry; the names follow the SVG and PostScript fill rules and Clipper2 | `src/clip.zig`, `src/offset.zig` | The rule that decides if a point is inside a polygon set. |
| Shoelace formula for polygon area | Mathematics | `src/geom.zig` | The signed area of a polygon. |
| Sweep and prune (sort by one axis, test only the overlapping intervals) | General technique | `src/clip.zig` | Finds candidate edge pairs for the intersection test. |
| STL file format, 3D Systems. Description: https://en.wikipedia.org/wiki/STL_(file_format) | File format | `src/mesh.zig` | The binary and ASCII STL loader and the binary STL writer. |
| Integer coordinates in micrometers, as in CuraEngine (https://github.com/Ultimaker/CuraEngine) | AGPL-3.0 | `src/geom.zig` | The coordinate unit. CuraEngine uses 1 unit = 1 micrometer (`include/types/Coord_t.h`). zslice uses the same unit. No code is copied. |
| CuraEngine G-code comments: `;FLAVOR:`, `;LAYER_COUNT:`, `;LAYER:n`, `;TYPE:WALL-OUTER`, `WALL-INNER`, `SKIN`, `FILL` | AGPL-3.0 (the convention, not code) | `src/gcode.zig` | The comment names, so that G-code viewers and printdeck (`deck/internal/gcode/gcode.go`) find the layers and features. |
| Scanline polygon fill (sort the edge crossings on each line, fill between them by winding number) | General computer graphics technique | `src/infill.zig` | The line infill. |
| Greedy nearest-neighbor path order | General technique | `src/layer.zig` | The order of the paths in a layer. |
| Mathematical morphology "opening" (erode, then dilate) | General technique | `src/offset.zig`, `src/layer.zig` | Removes skin areas that are too thin to print. |
| Iterated snap rounding (repeat the intersection pass on the rounded result) | General computational geometry technique | `src/clip.zig` | Makes the boolean operations robust after crossing points are rounded to the grid. |
