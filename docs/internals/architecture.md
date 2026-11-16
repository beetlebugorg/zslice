# Architecture

Read [How a slicer works](how-slicing-works.md) first. It explains the stages. This document explains how the code is organized.

## Modules

```
src/
  root.zig       The public Zig API. It exports the modules and the main types.
  main.zig       The command line tool.
  c_api.zig      The C API of the slicer (zslice.h), the status codes, and
                 the wasm exports. c_api/app.zig and c_api/view.zig have the
                 app API and the 3D view API (zslice-app.h).

  Stages, in pipeline order:
  mesh.zig       Mesh, Builder (vertex weld), STL load and write, test shapes.
  slicer.zig     Layer table, face index, mesh -> layer outline.
  layer.zig      Layer plan: walls, skin, infill, path order.
  support.zig    Support areas under overhangs (grid support).
  tree_support.zig  Tree support: branches that join on the way down.
  gcode.zig      Emitter: layer plans -> G-code, statistics.
  engine.zig     Job: runs all stages with threads, and reuses the work
                 of an older job.

  Tools that the stages use:
  geom.zig       Point, Paths (flat polygon store), area, simplify.
  clip.zig       Polygon booleans.
  clip_open.zig  Clip open polylines to a region.
  offset.zig     Polygon offset.
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
  profile.zig    Profiles in TOML files. toml.zig: the parser.
  import_cura.zig  Import of Cura profile stacks.

  The app core (see docs/app/README.md):
  app.zig        The state of the app: the plates, the settings, the
                 overrides, the support marks, and the slice worker.
  app/toolpaths.zig  The paths of a slice for the previews, and the pick.
  app/inspect.zig    The values of one path and the reasons for them.
  app/feature_settings.zig  The settings that change each feature.
  app/setting_effect.zig    What a setting changes in the preview.
  app/setting_info.zig      The description of each setting for a panel.
  app/licenses.zig          The licenses for a Licenses screen.
  render/view.zig  The 3D view: the scene, the camera, the beads.
  render/vk.zig    The Vulkan backend of the 3D view.
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

## Memory model

zslice uses arenas for temporary memory. An arena frees all its memory in one step, so the code needs no `free` for each temporary array.

- Each boolean, offset, fill, and plan takes an arena for its intermediate data from the pool in `scratch.zig`, and gives it back at the end. The arena keeps its memory (up to 16 MB) for the next call, so a slice does not get new pages from the operating system for each call. The engine frees the memory of the pool at the end of a slice. The result of a call goes in the allocator of the caller.
- `layer.plan` puts the plan in its own arena (it lives until the G-code is written).
- `slicer.sliceAt` uses a pool arena for the segments and chains of a layer.
- The memo of each layer (`layer.Memo`) has its own arena with the results of the slow steps (offsets, skin, fill regions) by their inputs. An app keeps the memos for the next slice (`Job.initReuse`). A one-shot slice frees each memo after the plan of its layer (`Job.keep_memos`).

Long-lived memory:

| Data | Lifetime | Size |
|---|---|---|
| Mesh | The whole slice | 12 bytes for each vertex, 12 bytes for each triangle |
| Face index | Pass 1 | 4 bytes for each (triangle, layer) crossing |
| Outlines and surfaces | The whole slice | 16 bytes for each outline point |
| Memos | The slice, or until the next slice of an app | The results of the slow steps of a layer |
| Layer plans and their G-code text | A ring of a few layers for each thread | 16 bytes for each path point |

## Threads

`parallel.forEach(threads, n, ctx, func)` runs `func(ctx, i)` for each i on a set of threads. Each thread takes the next i from one atomic counter.

- Pass 1 writes `outlines[i]` from thread i. Each slot has one writer.
- The face index of pass 1 is made in blocks of faces on all threads. Each block counts its faces in each layer, and a prefix sum gives each block its part of each layer, so the faces of a layer stay in face order.
- Pass 2 is a pipeline (`engine.Pipeline`). A thread plans layer i into slot i mod (ring size) of a ring. The same thread then does the work of the emitter that does not depend on the layers before (`gcode.prepare`): the combing ways of the travels and the lengths of the moves. The calling thread makes a dry run of the emitter for each planned layer, in layer order: it finds the emitter state at the start of the layer and formats no numbers. It uses a prepared way or length only if the nozzle is at the point that it was found from. Then any thread writes the G-code text of the layer with a copy of that state, and the calling thread writes the texts out in layer order. A thread that waits sleeps on a `parallel.Signal`.
- A cancel stops pass 2 between the steps of a layer plan (`layer.Context.cancel`). The pipeline drops a plan that stopped early. The memos get only complete results, so the next slice can use them.

The work of each item depends only on its index and on data that does not change during the pass. Thus the output is the same for each thread count. A test checks this (`engine.zig`).

On wasm, `parallel.has_threads` is false and the loop runs on the calling thread.

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
