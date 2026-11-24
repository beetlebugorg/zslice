# Architecture

Read [How a slicer works](how-slicing-works.md) first. It explains the stages. This document explains how the code is organized.

## Modules

This list has the main modules. `ls src src/app src/c_api src/render` lists all files.

```
src/
  root.zig       The public Zig API. It exports the modules and the main types.
  main.zig       The command line tool.
  c_api.zig      The C API of the slicer (zslice.h), the status codes, and
                 the wasm exports. The files of c_api/ have the API of
                 zslice-app.h: app.zig (the app), set.zig (the plate set),
                 view.zig (the 3D view), and paint, label, gcode, farm,
                 printers, project, and sign.

  Stages, in pipeline order:
  mesh.zig       Mesh, Builder (vertex weld), STL load and write, test shapes.
  slicer.zig     Layer table, face index, mesh -> layer outline.
  layer.zig      Layer plan: walls, skin, infill, path order.
  arachne.zig    Arachne walls with a variable line width (a port of
                 CuraEngine): arachne/beading.zig, skeletal.zig,
                 extrusion.zig, walls.zig.
  slope.zig      Slope smoothing: beads in the steps of sloped tops.
  support.zig    Support areas under overhangs (grid support).
  tree_support.zig  Tree support: branches that join on the way down.
  lightning.zig  Lightning infill: branches under the tops, grown from the
                 top layer down.
  gcode.zig      Emitter: layer plans -> G-code, statistics.
  gcode_vars.zig The variables of the start and end G-code: the names
                 of zslice, Cura, PrusaSlicer, OrcaSlicer, and Bambu
                 Studio, and their expression syntax.
  engine.zig     Job: runs all stages with threads, and reuses the work
                 of an older job.

  Tools that the stages use:
  geom.zig       Point, Paths (flat polygon store), area, simplify.
  clip.zig       Polygon booleans.
  clip_open.zig  Clip open polylines to a region.
  offset.zig     Polygon offset.
  voronoi.zig    Voronoi diagram of points and segments (a port of
                 boost::polygon), with voronoi_predicates.zig and
                 voronoi_ctypes.zig.
  infill.zig     Scanline line fill, and the other infill patterns.
  flow.zig       The shape and the volume of a bead.
  motion.zig     Motion planner: the time of each move with acceleration.
  settings.zig   Settings, Resolved (derived values), Feature.
  settings_meta.zig  The section and the help text of each setting (made by
                 tools/settings_doc.py).
  parallel.zig   Parallel for loop, and a signal that threads wait on.
  scratch.zig    A pool of arenas for work memory.
  svg.zig        SVG picture of a layer plan.

  Models, plates, and profiles:
  plate.zig      The parts on the bed, their places, and the arrangement.
  orient.zig     The orientation of a part with the least support.
  islands.zig    Shapes that start in the air.
  threemf.zig    3MF load and save. zipfile.zig: the zip container.
  filaments.zig  The filaments of a plate, and the flush of a change.
  paint.zig      The paint of a part (a filament for each triangle), the
                 brush, and the regions of the smart select.
  body_region.zig  The settings and the filament of a selected body of
                 some layers: a volume, a prism stack of its footprints.
  paint_split.zig  The split of the layers of a painted part into the
                 regions of its filaments.
  profile.zig    Profiles in TOML files. toml.zig: the parser.
  import_cura.zig  Import of Cura profile stacks.
  cura_compare.zig  The zslice settings next to the settings of a Cura
                 stack.

  The app core (see docs/app/README.md):
  app.zig        The state of the app: the plates, the settings, the
                 overrides, the support marks, and the slice worker.
  app/toolpaths.zig  The paths of a slice for the previews, and the pick.
  app/inspect.zig    The values of one path and the reasons for them.
  app/feature_settings.zig  The settings that change each feature.
  app/setting_effect.zig    What a setting changes in the preview.
  app/setting_info.zig      The description of each setting for a panel.
  app/history.zig    The undo list of each app (the steps, the amend of
                 one edit, undo, redo, goto, truncate), and the changes
                 of a step in words.
  app/plate_set.zig  The plate set: one app for each plate, the
                 active plate, the status of each, the order of the
                 slices, project loads, and the sync of a view.
  app/licenses.zig          The licenses for a Licenses screen.
  render/view.zig  The 3D view: the scene, the camera, the beads.
  render/plates.zig  The other plates of a set in the view, and the
                 light beads of a slice for a far camera.
  render/vk.zig    The Vulkan backend of the 3D view.
  render/web.zig   The web backend: the frame data for WebGL2.
```

The dependencies go one way: stages use tools, and later stages use earlier stages. No tool uses a stage, with two exceptions: `svg.zig` reads a layer plan (it is an output, like `gcode.zig`), and a test in `offset.zig` uses `slicer.zig` to make a real input. The app core uses the stages and the tools. No stage or tool uses the app core.

## Data flow

```
STL bytes
  -> Mesh                     (mesh.zig)
  -> []Layer, FaceIndex       (slicer.zig)
  -> []Paths  (one outline for each layer)    pass 1, parallel
  -> top and bottom surfaces of each layer     parallel
  -> LayerPlan (a ring of a few layers)       pass 2, parallel
  -> G-code text, Stats       (gcode.zig)     in layer order
```

## Conventions

These rules hold everywhere. Code that breaks one of them makes wrong output in a later stage, not an error.

- **Units.** 2D coordinates are `i64` micrometers (`geom.Point`). Settings are `f64` millimeters. Convert with `geom.fromMm` and `geom.toMm`. Mesh vertices are `f32` millimeters.
- **Orientation.** A closed polygon has the material on its left. Outer boundaries are counterclockwise and holes are clockwise. Each boolean and offset result follows this rule. Code that makes polygons from other sources must give them the same orientation, or pass them through `clip.unionAll` with `.non_zero`.
- **Closed polygons.** A closed polygon does not repeat its first point at the end. The edge from the last point to the first point is implicit.
- **Exact predicates.** Tests on points (left of, on, crossing) use the integer functions `geom.cross3` and `geom.dot3`, in i128. Floating point is only for constructions (a new point), and the result is rounded to the grid.

## Data types

### `geom.Paths`

A set of paths in two flat arrays: `points` (all points, one path after the other) and `ends` (the end index of each path). One set has two allocations, not one for each path. `get(i)` returns the points of path i as a slice.

Build a set with `append(gpa, points)`, or point by point with `appendPoint` and `endPath`.

### `layer.LayerPlan`

The paths of one layer, in print order. It has its own arena: `deinit` frees all of it in one step. `paths.items[i]` has the feature and the closed flag of `points.get(i)`.

### `settings.Settings` and `settings.Resolved`

`Settings` has the values that the user sets. `Resolved` comes from `Settings.resolve()`: it has the derived values (the line width when it is 0, the skin layer count from the thickness, the filament area) and the `speed` function. Code after the engine start uses `Resolved`, so that each derived value has one definition.

A layer with overrides has its own `Resolved` (`Job.resolvedAt`). [Settings for some layers](layer-settings.md) lists the settings that can change per layer, and the code that reads them.

## Memory model

zslice uses arenas for temporary memory. An arena frees all its memory in one step, so the code needs no `free` for each temporary array.

- Each boolean, offset, fill, and plan takes an arena for its intermediate data from the pool in `scratch.zig`, and gives it back at the end. The arena keeps its memory (up to 16 MB) for the next call, so a slice does not get new pages from the operating system for each call. The engine frees the memory of the pool at the end of a slice. The result of a call goes in the allocator of the caller.
- `layer.plan` puts the plan in its own arena (it lives until the G-code is written).
- `slicer.sliceAt` uses a pool arena for the segments and chains of a layer.
- The memo of each layer (`layer.Memo`) has its own arena with the results of the slow steps (offsets, skin, fill regions) by their inputs. An app keeps the memos for the next slice (`Job.initReuse`). A memo whose results the last two slices used moves to the new job with no copy (`Memo.keepsAll`). A one-shot slice frees each memo after the plan of its layer (`Job.keep_memos`).

Long-lived memory:

| Data | Lifetime | Size |
|---|---|---|
| Mesh | The whole slice. An app keeps the placed mesh of each part until the part changes (`App.placed`) | 12 bytes for each vertex, 12 bytes for each triangle |
| Face index | Pass 1 | 4 bytes for each (triangle, layer) crossing |
| Outlines and surfaces | The whole slice | 16 bytes for each outline point |
| Memos | The slice, or until the next slice of an app | The results of the slow steps of a layer |
| Layer plans and their G-code text | A ring of a few layers for each thread | 16 bytes for each path point |

## Threads

`parallel.forEach(threads, n, ctx, func)` runs `func(ctx, i)` for each i on a set of threads. Each thread takes the next i from one atomic counter.

- Pass 1 writes `outlines[i]` from thread i. Each slot has one writer.
- The face index of pass 1 is made in blocks of faces on all threads. Each block counts its faces in each layer, and a prefix sum gives each block its part of each layer, so the faces of a layer stay in face order.
- Pass 2 is a pipeline (`engine.Pipeline`). A thread plans layer i into slot i mod (ring size) of a ring. The same thread then does the work of the emitter that does not depend on the layers before (`gcode.prepare`): the combing ways of the travels and the lengths of the moves. The calling thread makes a dry run of the emitter for each planned layer, in layer order: it finds the emitter state at the start of the layer and formats no numbers. It uses a prepared way or length only if the nozzle is at the point that it was found from. Then any thread writes the G-code text of the layer with a copy of that state. Any thread sends the texts out in layer order, one thread at a time, and gives each layer to the sink (the toolpaths of the view). The calling thread does the dry runs first, because no other thread can do them: they limit the time of a slice after a small change. A thread that waits sleeps on a `parallel.Signal`.
- A cancel stops pass 2 between the steps of a layer plan (`layer.Context.cancel`). The pipeline drops a plan that stopped early. The memos get only complete results, so the next slice can use them.

The work of each item depends only on its index and on data that does not change during the pass. Thus the output is the same for each thread count. A test checks this (`engine.zig`).

On wasm, `parallel.has_threads` is false and the loop runs on the calling thread.

## Speed in WebAssembly

The wasm module runs the same code as the native build. Some code that is fast on x86-64 is slow in wasm. Keep these rules in the hot loops:

- **No 128-bit product.** Wasm has no instruction for a 64 x 64 -> 128 bit product, so each one is a call of a library function (`__multi3`). Use `geom.mulSub` and `geom.mulAdd` (and `geom.cross3`, `geom.dot3`, `Point.dist`, which use them): in wasm they use 64-bit products when the factors are small. `clip.zig` has its own 64-bit forms for coordinates in range (`Arith`).
- **No float `@min`, `@max`, or `@round`.** Wasm has other rules for NaN and for a half than C, so each of these is a call of a library function. Use `geom.fmin`, `geom.fmax`, and `geom.round`.
- **No division for an index.** A band, a slab, or a grid cell has a width that is a power of two, so its number is a shift (`clip.Grid`, `clip.SlabIndex`, `geom.EdgeIndex`, `infill.Boundary`). A walk around a polygon steps with a comparison, and not with a modulo.
- **No copy with a length that is known only when the code runs.** It is a call into the host (`memory.copy`). Copy a fixed count of bytes (see `gcode.Line.addDigits`), or a struct.
- **Small functions for the hot loops, and pointers to the items.** The compiler of the host keeps the values of a small loop in registers. In a very large function (after much inlining) it keeps them on the stack. A copy of a 48-byte struct from an array costs six loads and stores. See `clip.testCells`.
- **Threads: sync the memory size.** V8 keeps the size of the shared memory in each instance. A thread must do a `memory.grow` of 0 pages before it uses memory that another thread added (`wasm_heap.sync`). Without it, a `memory.fill` or `memory.copy` can trap, and the slice then waits for the thread with no end.

Measure each change in wasm and native, on one thread and on all threads, and check that the G-code is the same. `web/app/README.md` tells what helps the first slice of a visit.

## Error handling

- Allocation errors go up to the caller as `error.OutOfMemory`.
- Bad input (a broken STL file, bad settings) returns an error from `Mesh.fromStl` or `Settings.resolve`.
- Bad geometry is not an error. A mesh with holes or overlaps gives the best output that the code can make: open chains are closed or removed, and overlaps are joined by a union.

## The C API layer

`c_api.zig` and the files in `c_api/` are a thin layer:

- Each exported function checks its pointers, calls the Zig API, and changes the Zig error to a status code.
- `CSettings` has `Settings` and an arena for the string values, because `Settings.set` does not copy strings.
- `CallbackWriter` is a `std.Io.Writer` that sends its buffer to the C callback.
- The wasm build compiles the same file for `wasm32-freestanding`.
- Each function that changes the state of an app notes the change for its undo list (`noted` in `c_api/app.zig`): the name of one setting, or "more", and a flag for a change of the plate. The Zig functions of `App` do not note changes. A Zig shell that calls them directly calls `App.undo.note` itself.

## The undo list

The undo list is in the core (`src/app/history.zig`), one list for each app. The GTK shell and the web app had a copy each; now they call `zs_app_history_*`. A shell keeps only three things:

1. The timer. It calls `zs_app_history_commit` 400 ms after the last change, with the time. The core has no clock, also in wasm.
2. The focus. It calls `zs_app_history_set_focus` with the setting of the editor that has the focus. The edits of one setting are one step while its editor keeps the focus.
3. The UI: the history list, the undo, redo, and history buttons of the dock, and the undo and redo keys. After an undo, it updates its editors from the bits of `enum zs_history_restored`, saves the groups that changed, and slices again.

A step keeps the texts of the three groups (`zs_app_state_write`), the quality profile, the plate as a 3MF file (steps with the same plate share one file), and the facts of the state. The text of a step comes from the diff of its facts and the facts of the step before. A plate set has one app for each plate, so each plate has its own undo list. The plates themselves are not in an undo list: a removal of a plate cannot be undone.

## The plate set

The plate set is in the core (`src/app/plate_set.zig`, `zs_set_*`). A `zs_set` owns one `zs_app` for each plate. The shells had a copy each (the web worker had the list of plates, and the GTK app had the `PlateSlot` swap in one app); now they call `zs_set_*`, and the `zs_app_*` calls on the app of the active plate (`zs_set_app`).

- The status of a plate comes from the state of its app and two marks of the set: wanted (a slice waits) and cannot (a resin plate). `zs_set_plate_info` gives it with the id (new for each plate), the bed, the name, the printer key, the part count, and the message of a load.
- The order: a change (`zs_set_changed`) marks a plate wanted. The active plate slices first, then the other wanted plates in order, one at a time. A held change (`zs_set_changed_held`) waits for `zs_set_release`, so a drag slices once at the end.
- Two modes. Native (`zs_set_new`): the core starts each slice on its threads. A change of the active plate starts its slice at once and stops a background slice; that plate slices again later. A slice thread never waits for the lock of the set: it marks the work as pending, and the holder of the lock starts the next slice. wasm (`zs_set_new_web`): a slice runs on the calling thread, and the worker calls `zs_set_step` from a timer, so the messages of the page come between the slices.
- Projects: `zs_set_project_load` loads all plates of a printdeck.yml, one app for each plate. A plate with no Cura stack gets its parts (for the footprints) and the status cannot.
- The view: `zs_set_view_sync` gives a view the beds, the clears where another plate came to a place (by id), the flags, the footprints, and the beads of the other plates with a new slice. The set keeps the scene bytes of the last slice of each plate, so a plate that slices again shows its old beads. The web app slices in a worker and draws on the page: `zs_set_sync_write` writes the same sync as bytes, and `zs_view_sync_read` applies it to the view of the page.
- The shells keep the UI: the plate bar, the labels, the keys, the framing of the camera, and the question before a removal.

## The slice form

The app keeps the work of a slice for the next slice: the outlines of each part, the memo of each layer, and the move stream of each level. A later slice makes a piece again only if its key changed. A key is a 64-bit hash (`std.hash.Wyhash`) of all inputs that the stages of the piece read. `src/form.zig` has the key builder and the kept form of each level.

A key reads every setting, minus a skip list for its tier (`src/settings_tiers.zig`). A setting with no line in that table is in each key. So a new setting can make a slice slower, but it cannot make a slice wrong. The tiers:

| Tier | Piece | Key | Skips |
|---|---|---|---|
| Geometry | The outlines of a part | `engine.outlineKey` | All settings but 11 (the layer heights, the shrinkage, the XY offsets, the resolution, the gap closing, the polyholes, `project.fast_offsets`) |
| Regions, paths | The memo of a layer, the move stream of a level | The value keys of the memo, `PlateJob.levelKey` | The patch settings (`settings.patch_settings`) |
| Text | The G-code of a level | None yet | Nothing |

No tier reads the six app preferences (`engine.threads`, `engine.draft_slices`, `engine.auto_simulate`, `engine.slice_form`, `engine.verify_slices`, `engine.form_budget_mb`). A name enters a skip list only with a search of the code of the tier and a pass of `zslice verify --sweep` (see [The slice verifier](code-quality.md#the-slice-verifier)).

The key of a level (`PlateJob.levelKey`) hashes the inputs of all levels (`planStamp`), the index, the z, and the height of the level, the support of the level, and the support of the level under it. The stream of a level starts where the level under it ends, so a change under it makes it dirty too. `PlateJob.forms` keeps two generations of the stream of each level (`form.LevelForm`): the stream of the last slice, and the stream before it. So an undo of a change plans no level. With `engine.slice_form` off, only one generation stays, and the reuse is as before the slice form.

The placed mesh of each part (the mesh on the bed) is the first piece. `plate.Part.mesh_key` is a hash of the vertices and the faces of the mesh of the part. Each change of that mesh sets the key to 0 (`Part.touchMesh`), and the next slice makes it again. `App.makeSlicePlan` keeps the placed mesh of each part and each modifier volume (`App.placed`) with a key of the mesh key and the place (`Part.placedKey`). A slice with no change of the plate copies no mesh and hashes no mesh. The outline key of a job has the key of its placed mesh (`Job.Options.mesh_key`), so an old job of another mesh gives no work. `zslice verify` checks after each step that each known mesh key is the key of the mesh now (`App.meshKeysFresh`).

With `engine.slice_form` on, a change of the plate (a move, a turn, an add, or a delete of a part) keeps the job before. The job of each part takes the work of the old job of the same stable part id (`PartInput.id`) if its outline key is the same. `Job.part_key` hashes the outline key of the part, its paths settings, its modifiers, its paint, its labels, and its picks (`plate_job.partKey`). The key of a level then has the inputs of all levels (`PlateJob.restKey`: the plate settings, the overrides that are not local, the ids of the parts in order, the prime towers), and for each part on the level its part key, its id, its move, and its layer. A level under `layer.ringLevels` also has a hash of the first layers of all parts, for the skirt and the brim. So a move of one part plans only the levels of that part, and the level over its top for the first travel.

A slot holds a key and the stream that the key made, as a pair. The pipeline frees the old stream of a level first, then stores the new stream, then its key (`Pipeline.writeOne`). So a cancel or a failed encode leaves a slot with no key, and the next slice plans that level.
