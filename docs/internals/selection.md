# Selection and focus

The core has one model of what the user points at. The code is in `src/app/selection.zig`, and the C calls are the `zs_sel_*` functions of `include/zslice-app.h`. A shell reads and changes the selection only through these calls.

## The fault that this model removes

Each shell kept its own copy of the selection. A selected part was an index, and a copy of the part from the worker. After a move, a delete, a plate change, or an undo, that index could name another part. A late reply of the worker could also write an old state over a newer click.

## The state

| State | Identity | Notes |
|---|---|---|
| Active plate | Plate index | The reported plate, and a request of the user until its reply |
| Selected parts | Stable part ids | An ordered list. The last id is the primary part |
| Selected line | The key of the line (`edits.pathKey`) | With its path index and segment in the slice now |
| Hover | Stable part id | 0: none |
| Tool | An integer of the shell | The web app: select, move, measure, support |
| Camera target | Plate index, or all plates | A request. It waits until its plate is active |

The model also has three tables of parts:

- `parts`: the facts of the owner of the plates.
- `over`: the local places of a drag. These places are newer than the facts.
- `scene`: the places of the beads that the view shows now.

## Stable part ids

`plate.Part.id` is a number over 0. It is unique on its plate.

| Event | The id |
|---|---|
| A move, a turn, a scale | Stays |
| A delete of another part | Stays. The index can change |
| A move to another plate | Stays, if the id is free on that plate |
| A copy, a paste, a duplicate | A new id |
| A split or a cut | New ids for the pieces |
| Undo and redo | The snapshot has the ids, so each part comes back with its id |
| A save and a load | The `partid` lines of `Metadata/zslice_overrides.txt` keep the ids |

An older version of zslice leaves the `partid` lines out. Undo lists are per plate. So an undo of a move to another plate can show the same id on two plates. The model is safe in this case, because it looks up an id only on the active plate.

## The generation rule

1. Each change of the model adds 1 to the generation (`zs_sel_generation`).
2. A shell with a worker notes the generation when it sends a request.
3. When the reply comes, the shell calls `zs_sel_answered` with that generation.
4. `zs_sel_answered` ends the local places and the plate request of that age or older.
5. A local change that is newer than the reply stays.

So a late reply never undoes a newer click. A request that fails also gets a reply, so a plate request never stays open.

A reply that selects parts (a paste, a duplicate) must also check that the user changed no selection since the request. The web app uses a stamp for this (`tools.selectReply`).

## The pick

`zs_sel_pick(sel, view, px, py)` gives the id of the part under a pixel. It needs no slice and no reply.

1. The bead under the pixel names a part, if the beads of that part are at its current place.
2. A part that moved since the slice in the view has beads at an old place. Its box at the current place counts in place of its beads.
3. The nearest candidate along the ray wins.
4. With no candidate, the smallest footprint under the bed point wins.

The pick returns 0 while a plate request is open, because the table is still of the plate before.

## A selected line

A new slice can renumber the paths. The model keeps the key of the line. After a slice, a shell finds the path of that key (`zs_app_path_of_key`) and calls `zs_sel_line_found`. A draft slice can miss the key of a line that the exact slice makes again. So on a miss, a shell looks at the saved place: the same layer and feature, and the nearest line (`zs_app_pick_feature`). It selects that line with its own key, and the exact slice after the draft goes back to the first key and segment. With no line at that place, the line selection ends.

## A click on a gizmo handle

A handle of the gizmo can lie over another part. A press and a release at one place is a click, so the click goes to the part under the pointer. A drag starts only after the pointer moves more than 4 CSS pixels.

## The C calls in order

For a shell with no worker (GTK, the Mac, Windows):

1. `zs_sel_new` once.
2. `zs_sel_sync(sel, set, 0)` after each change of the set.
3. `zs_sel_sync(sel, set, 1)` after the view loads a slice.
4. On a click: `zs_sel_pick`, then `zs_sel_select` with a mode.
5. On a drag: `zs_sel_place` on each frame. Send the place to the app at the end, or as the shell does now.
6. To change the plate: `zs_sel_plate_request`, `zs_set_select`, then `zs_sel_sync`. The sync ends the request.
7. To act on a part: `zs_app_part_index(app, id)`. Never keep the index.
8. After a slice: `zs_app_path_of_key` for the key of `zs_sel_line_get`, then `zs_sel_line_found`. On a miss, use the saved place (see "A selected line").
9. `zs_sel_free` at the end.

For a shell with a worker (the web app):

1. The worker sends the table (`zs_app_sel_parts`) before the reply of each call that changed it.
2. The page calls `zs_sel_set_parts` with the table, and `zs_sel_set_scene` when the view loads a scene.
3. The page calls `zs_sel_plate_report` for each list of plates.
4. The client sends the generation with each call, and the stable id of each part that the call names.
5. The worker finds the index of the id. A call for a part that is gone does nothing.

## Notes for the Mac and Windows ports

The older calls still work, so a shell can move in steps.

Delete from the shell:

- Each stored part index, and each stored copy of a part as the selection.
- Each stored selected path index that outlives a slice. Keep the key.
- Each "wanted plate" or "frame this plate" flag.
- Each pick that asks the app for the part of a path. Call `zs_sel_pick`.

Port in this order:

1. Make one `zs_selection` next to the `zs_set`. Call `zs_sel_sync` after each change of the set and after each view load.
2. Move the part pick and the selection of parts to the model.
3. Find each call with a part index. Get the index from the id just before the call.
4. Move the active plate and the camera target.
5. Move the line selection to the key.
6. For the transform tool: call `zs_sel_place` on each frame of a drag. Treat a press and a release at one place on a handle as a click on the part under the pointer.

The transform tool of Windows can start at step 6 once steps 1 to 3 work.

The Mac app has all six steps. `Workspace.selectedIDs` holds the ids, and `selectedPart` and `selectedParts` read each index from its id. The line is its key, and a drag calls `zs_sel_place` on each event.
