# 16. Performance

## Goal

Make a change of a setting show in the view at once, at 60 frames a second, and make the app start at once. Read this part before part 01, because its rules shape the data structures. Apply the measured work at the end of each part, and check each step with `zslice bench` and the test hooks of the apps.

## Read first

- [README.md](../README.md), section "Speed": the user-facing numbers.
- [Architecture](../docs/internals/architecture.md), sections "Memory model", "Threads", and "Speed in WebAssembly".
- [The command line](../docs/user/command-line.md), section "Measure the speed".
- [web/app/README.md](../web/app/README.md), section "Performance".
- [The macOS app internals](../docs/internals/macos.md), sections "The 3D view" and "The beads".

## The targets

On a 3DBenchy with 8 cores (from the README):

- A full slice: about 0.3 s.
- A change of a speed, the fan, a temperature, or the flow: about 15 ms. The paths stay; only the G-code is made again.
- A change of the infill: about 30 ms. A change of the walls: about 0.2 s.
- A drag of a part, a tree branch, or a setting slider shows the result as you move.
- A new change stops a slice that runs in under 15 ms.
- The view: 60 frames a second. A pick: under a millisecond.

## The methods, in the order they paid off

1. **Keep the work of the last slice.** The memo of each layer keeps the results of the slow steps (offsets, skin, fill regions) by their inputs. An app keeps the memos for the next slice. Only complete results go into a memo, so a cancel never leaves a bad entry.
2. **Move streams.** A stream is a flat copy of a layer plan with no setting value (`src/stream.zig`). A change of a setting that changes no path (speeds, accelerations, flow, fan, cooling times, temperatures) makes no plan: each level runs from its stream with the new settings. A wall speed change of the Benchy went from 30 ms to 12 ms. `zslice bench --only patch` checks the same G-code for 31 settings on 5 cases.
3. **A pool of arenas** (`src/scratch.zig`) for booleans and offsets.
4. **Fast booleans.** A grid of crossings with a radix sort on a dense cell index. In a later snap rounding pass, test only pairs with a new edge. The crossing search of the pod body went from 2.0 s to 0.8 s of CPU on one thread.
5. **The paint split with a distance field** (part 05): from 4 to 22 s and 3 to 9 GB to 90 ms on 8 threads for a brushed 3DBenchy hull.
6. **Line cuts** (`src/dexel.zig`): cut the outline of a layer with lines one line width apart, and merge the intervals of two layers line by line. The skin of all layers of the 3DBenchy from line cuts needs 13 ms, against 906 ms with polygon booleans, on one thread, and the areas agree to 0.015 %. This was the owner's idea: slice in two directions and use the intersection as the fill lines. The planner does not use the cuts yet (`zslice bench --only dexel`).
7. **The fast offset experiment** (`project.fast_offsets`, off by default): 2440 of the 3699 unions of a Benchy had more than 16 crossings from the small loops of closing corners. Put the crossing point in place of the loop: about 11 % less CPU. The outer walls stay within 1.4 µm. Off, the G-code is the same.
8. **A coarse slice during a drag.** A turned part slices with thick layers, one wall, no skin, and no infill during a ring drag: 85 ms against 864 ms in the browser for a Benchy.
9. **Light levels and culling in the view** (part 08), and a detail governor while the view moves on the web.
10. **Keep the UI thread free.** History steps as snapshots (297 ms to 11 ms per move). The session written on a thread (Linux, 490 to 660 ms off the UI thread). The web session in IndexedDB from the worker (0.5 s off the main thread). Scene bytes made by the worker (88 to 109 ms off the UI thread).

## WebAssembly rules

Keep these in each hot loop (from the architecture page):

- No 128-bit products: use `geom.mulSub` and `geom.mulAdd`.
- No float `@min`, `@max`, or `@round`: use `geom.fmin`, `geom.fmax`, `geom.round`.
- No division for an index: a power-of-two cell width and a shift.
- No copy with a length known only at run time.
- Small functions for the hot loops, and pointers to the items.
- Threads: sync the memory size of each thread with a `memory.grow` of 0 pages.

## Rules

- Measure each change in wasm and native, on one thread and on all threads.
- Check that the G-code is the same, byte for byte, before and after a speed change.
- Use the logs of stalls: `ZSLICE_STALLS=ms` (Linux and Mac) logs each wait of the UI thread over that time, with stacks.
- Use the benches: `zslice bench part.stl` (full, late, wall count), `--only sim`, `--only paint`, `--only dexel`, `--only patch`, and `--runs n`.

## Open work (from the roadmap)

- The support column pass runs on one thread. The slowest corpus file with support needs 11 s on 2 threads.
- Faster skin regions: a sliding window for the stacked intersection, then SIMD in the boolean.
- Tree support: faster (1.4 s on the camera arm, grid 0.4 s).

## Acceptance checks

1. `zslice bench benchy.stl` gives a full slice, a late change, and a wall count change near the targets above on the hardware of the test.
2. `zslice bench --only patch` gives the same G-code as a new slice for each patch setting.
3. An orbit, a pan, a zoom, and a slider move hold 60 frames a second on eight Benchies in the web app on a desktop GPU.
4. No stall over 50 ms on the UI thread during a slice, a move, and a session write.
