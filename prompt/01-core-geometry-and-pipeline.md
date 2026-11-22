# 01. Core geometry and the slicing pipeline

## Goal

Build the Zig core from a mesh to G-code for one part: integer geometry, polygon booleans, polygon offset, mesh load, mesh slicing, and the engine that runs the stages on all threads. Also build the command line tool with an SVG layer preview. At the end, a 20 mm cube and a 3DBenchy slice to G-code.

## Read first

- [How a slicer works](../docs/internals/how-slicing-works.md): the stages from mesh to G-code.
- [Architecture](../docs/internals/architecture.md): the modules, the data types, the memory model, the threads, and the speed rules for wasm.
- [Papers and algorithms](../docs/references/papers-and-algorithms.md) and [Libraries](../docs/references/libraries.md): the sources of each method.
- [The command line](../docs/user/command-line.md).

## Build

1. `src/geom.zig`: points and polygons in integer coordinates. One unit is one micrometer. Integers give exact answers for "is this point left of this line" and "do these segments cross". CuraEngine uses the same unit.
2. `src/clip.zig`: union, intersection, difference, and xor by a planar arrangement and winding numbers. The steps are in its header. Find crossings with a uniform grid. Repeat the split passes until no pass finds a split point. If the passes stop at the limit, start again with snap rounding (hot pixels). When the first pass finds no split point and no point is in two loops, each loop is in the output whole or not at all: `clip.Simple` gives each loop its winding number from a crossing test of one of its points, and skips the merge, the faces, and the chain of the edges. The output must be correct for self-crossing polygons, shared edges, and polygons that touch at one point.
3. `src/offset.zig`: the offset of Clipper2. Move each edge along its normal. Join open corners with a miter, a round arc, or a bevel. At a closing corner, add the two moved end points with the original vertex between them. Then a union with the "positive" fill rule removes the loops that turn the wrong way. Before the move, simplify points within `clean_tolerance` of a line, and drop each loop that surely vanishes.
4. `src/mesh.zig`: STL (binary and ASCII) and OBJ. Weld vertices with bit-equal coordinates. Counterclockwise from outside is the outside. An OBJ has no unit: read it in mm. Later parts add 3MF (`threemf.zig`, `zipfile.zig`) and STEP (`step.zig`).
5. `src/slicer.zig`: the cut plane is at the middle of each layer. A vertex on the plane counts as below. Join segments into loops by the mesh edge id. Coordinates need a tolerance, and an id match is exact. Join open chains to the nearest chain start, and remove a chain that stays open. A non-zero union cleans the loops.
6. `src/parallel.zig`: `forEach(threads, n, ctx, func)` with one atomic counter. The first error stops the loop.
7. `src/scratch.zig`: a pool of arenas for the temporary memory of booleans and offsets. An arena keeps up to 16 MB for the next call.
8. `src/engine.zig`: resolve the settings, place the part (bottom at z = 0, or the z of the part on the plate with `Options.bed_z`, so a part sunk into the bed slices from z 0 and its lower part does not print), make the layer table and the face index, pass 1 (outlines, all threads), pass 2 (plans and G-code in batches, in layer order). The engine never holds the whole G-code file.
9. `src/main.zig`: the command line tool: `slice`, `layer` (an SVG of one layer, `svg.zig`), and later `bench`, `gaps`, `check`, `sweep`, `orient`, `printers`, `profile`, `import cura`, `import <file>` (the profile of another slicer, part 02), `gcode`. The CLI moves each part down or up to the bed before the slice, as the app does. A part that does not fit the printer slices with a warning; `--strict` refuses it.
10. `src/c_api.zig` and `include/zslice.h`: the small C API of the slicer (part 07 adds the app API). Each function returns a status (`ZS_OK` is 0). Each `_new` or `_load` has a `_free`.

## Numbers and rules that matter

- Bad input (a broken STL, bad settings) is an error. Bad geometry is not an error: a mesh with holes or overlaps gives the best output the code can make.
- Pass 2 is a pipeline: threads plan layers into a ring; the calling thread makes a dry run of the emitter for each planned layer in order; any thread writes the text of a layer from a copy of that state. See "Threads" in the architecture page.
- The output is the same for each thread count. Write a test for it.
- On wasm, `parallel.has_threads` is false. The module with threads (`zslice-mt.wasm`) uses a pool of waiting web workers in its place (`wasm_pool`, see part 09). With no pool, the loop runs on the calling thread.
- The status codes of `zslice.h` are fixed: 0 OK to 17 `ZS_PART_TOO_THIN`. Keep the numbers stable once a shell uses them.
- `zs_status_message` gives the same text for a person in each app.
- `engine.fitOf` gives the cause when a part does not fit (too high, too wide in X, too deep in Y) and the sizes of the part and of the printer (part 07).
- A part lower than half of the first layer (`PartTooThin`) is left out of the slice, and the other parts slice.

## Lessons

- The first boolean was O(n²) for long edges. It now finds crossings with a grid, and winding numbers with a walk over the faces (ROADMAP, "Performance").
- A grid walk of the booleans must stop at the edge of the grid ("Stop the grid walk of the booleans at the edge of the grid").
- A boolean whose passes do not end must fall back to snap rounding ("Snap round a boolean when its passes do not end").
- **A boolean with no split point needs no arrangement.** About half of the booleans of a 3DBenchy slice (2565 of 4874) find no split point in the first pass. The short path makes the same output, byte for byte, and saves 67 ms of CPU on a full slice. A test compares both paths on random loops for each operation and fill rule.
- **Put each part on the bed in the CLI.** A CAD export with its lowest point at z -80 sliced to no layers and failed with `EmptyMesh`.
- **Leave out a part too low to slice.** A flat name plate of 0.15 mm in a ZIP of the 3DBenchy parts failed the whole plate with "invalid argument". The slice now leaves that part out, and the fit check names it.
- The arena pool matters: a new arena for each call gets new pages from the operating system for each call, and each page costs a fault.

## Acceptance checks

1. `zig build test` passes.
2. `zslice slice cube.stl -o cube.gcode` slices a 20 mm cube (`tools/cube_stl.py` writes it).
3. The 3DBenchy slices, and `zslice layer` writes an SVG of a layer with walls, skin, and infill.
4. The corpus passes: `python3 -I tools/corpus.py zig-out/bin/zslice ../printdeck report.tsv`, each file `ok`.
5. The G-code is the same with 1 thread and with all threads.
6. A union of two squares that share a side gives one square. A self-crossing figure eight gives two loops.
7. The test of `clip.Simple` gives the output of the full boolean on random loops.
8. `zslice slice` of a mesh with its lowest point under z 0 slices.
