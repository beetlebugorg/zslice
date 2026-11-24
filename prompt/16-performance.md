# 16. Performance

## Goal

Make a change of a setting show in the view at once, at 60 frames a second, and make the app start at once. Read this part before part 01, because its rules shape the data structures. Apply the measured work at the end of each part, and check each step with `zslice bench` and the test hooks of the apps.

## Read first

- [README.md](../README.md), section "Speed": the user-facing numbers.
- [Architecture](../docs/internals/architecture.md), sections "Memory model", "Threads", and "Speed in WebAssembly".
- [Speed: the lower bound of a slice](../docs/internals/performance.md): the bound of each stage, and the stages that are furthest from it. For a 3DBenchy on the test machine (a 4-core i7-6700K), the bound is 95 ms on one thread and 24 ms on 4 cores. zslice needed 1477 ms of CPU on 2026-11-21. The booleans with no split point then saved 67 ms, and the table now gives 1410 ms (14.8 times the bound). The gap fill is 43 times its bound, the offsets 28 times, and the booleans outside the offsets 8.2 times. Tune the stage that is furthest from its bound first.
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
8. **A coarse slice during a drag.** A turned part slices with thick layers, one wall, no skin, and no infill during a ring drag: 85 ms against 864 ms in the browser for a Benchy. A draft slice (`zs_app_set_draft`) keeps all the paths for the view: an outline tolerance of 0.05 mm, no gap fill, classic walls. A draft of a 3DBenchy needs 480 ms of CPU, and the exact slice 1471 ms. A plate of 9 copies needs 730 ms for a draft and 1961 ms for the exact slice. A draft has no G-code for a file or a printer. Each app shows the draft first and slices exact 300 ms after the last change. In the GTK app, the view has the draft 106 to 194 ms after a wall count change of a 3DBenchy, where the exact slice needs 415 to 494 ms. In the web app (Chromium with no GPU), the draft needs 175 to 252 ms, and the exact slice up to 1.8 s.
9. **Light levels and culling in the view** (part 08), and a detail governor while the view moves on the web.
10. **Short integers in the exact Voronoi path** (`voronoi_ctypes.ExtendedIntN`): a product, a sum, or a difference of values with one or two chunks is one 128-bit operation in the caller. The gap fill lines of a 3DBenchy need 11 % less CPU, and a full slice 2 % less (1507 to 1477 ms). 89 % of the 2.25 M products had one or two chunks of 32 bits on each side. A test compares each short path with the loops on 200 000 random values. Wasm keeps the chunk loops.
11. **Booleans with no split point** (`clip.Simple`, part 01): in 2565 of the 4874 booleans of a 3DBenchy (481 000 of 1 111 000 edges), the first pass finds no split point. The output comes from the loops with no arrangement: 67 ms less CPU on a full slice (1532 to 1465 ms), and the same G-code.
12. **The Speed section** (part 02). On a 3DBenchy, CPU of a full slice (2026-11-22, a load average of 11): the defaults 1579 ms, `project.fast_offsets` 1406 ms (11 % less), `project.resolution` 0.010 mm 1260 ms (20 % less), both (Faster slicing) 1140 ms (28 % less), `project.gap_fill` off 1091 ms (31 % less), and Arachne walls 1832 ms (16 % more). The Faster slicing switch sets the first two.
13. **Build time.** The Mac builds its arm64 and x86_64 cores at the same time: a clean build in about 165 s in place of about 320 s on an 8-core Mac.
14. **Keep the UI thread free.** History steps as snapshots (297 ms to 11 ms per move). The session written on a thread (Linux, 490 to 660 ms off the UI thread). The web session in IndexedDB from the worker (0.5 s off the main thread). Scene bytes made by the worker (88 to 109 ms off the UI thread).
13. **A key for each level** (`src/form.zig`, `PlateJob.levelKey`, behind `engine.slice_form`, off by default). Each level keeps its stream with the key of all inputs of its plan, in two generations. A key reads every setting, minus a skip list (`src/settings_tiers.zig`): a new setting is in each key by default. A line edit and an override of `project.infill_density` or `project.wall_count` go into the keys of their own levels. On a 3DBenchy (2026-11-24, CPU): one line edit 146 to 49 ms (239 plans to 1), an undo of an infill change 142 to 47 ms (0 plans), the infill of z 5 to 10 mm 143 to 67 ms (26 plans), the walls of z 5 to 10 mm 292 to 218 ms. In wasm, the infill of z 5 to 10 mm went from 81 to 39 ms. The full slice costs 6.433 G instructions, as before.

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
- Use the benches: `zslice bench part.stl` (full, late, wall count), `--only sim`, `--only paint`, `--only dexel`, `--only patch`, `--only draft`, and `--runs n`.
- Prove that kept work changes no output: `zslice verify` (two apps, one keeps its work, one slices from the start) after each change to a key, a memo, or a stream. `zig build verify` runs it in the CI.
- `zslice bench --stages` prints the time of each stage and exact counts (plans, runs, texts, booleans, offsets). Compare the counts first: they do not depend on the load.
- A key keeps all settings but a proven skip list. Never write a list of the settings that a stage reads.

## Open work (from the roadmap)

- The support column pass runs on one thread. The slowest corpus file with support needs 11 s on 2 threads.
- Faster skin regions: a sliding window for the stacked intersection, then SIMD in the boolean.
- Tree support: faster (1.4 s on the camera arm, grid 0.4 s).
- A larger outline tolerance (`project.resolution`, from the lower bound page): 0.010 mm needs 19 % less CPU than 0.005 mm, and the outer walls move 10.4 µm or less for 99 % of their points. The default stays at 0.005 mm. The Faster slicing switch gives it to a user who asks.
- A proof for each closing corner of an offset was tried and not kept. It proved 24 000 of the 91 000 closing corners of a 3DBenchy, and the search for the proof made the offsets 11 % slower in instructions. The corners that it cannot prove are the ones that make the union slow.

## Acceptance checks

1. `zslice bench benchy.stl` gives a full slice, a late change, and a wall count change near the targets above on the hardware of the test.
2. `zslice bench --only patch` gives the same G-code as a new slice for each patch setting.
3. An orbit, a pan, a zoom, and a slider move hold 60 frames a second on eight Benchies in the web app on a desktop GPU.
4. No stall over 50 ms on the UI thread during a slice, a move, and a session write.
5. `zslice bench --only draft` gives the draft and the exact times, and the exact slice after a draft gives the G-code of before.
6. `zig build verify` passes, and fails when one input leaves a key (for example `project.fast_offsets` out of `engine.outlineKey`).
7. With `engine.slice_form=true`, `zslice bench --only edit` makes at most 2 plans, `--only undo` 0, and `--only zrange` at most 27, each with `same`.
