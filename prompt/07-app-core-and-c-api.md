# 07. The app core and the C API

## Goal

Build the app core: all logic of the zslice app, behind one C API, so that each shell only draws widgets, reads and writes files, and moves events to its UI thread. It has the plate and its parts, the plate set, the background slice, the undo list and the history, the inspection of a line, the settings descriptions, the checks, and the edits of lines. Then the 3D view (part 08) and the shells (parts 09 to 12) build on it.

## Read first

- [The app](../docs/app/README.md): the rule and the contract. Read it before any shell work.
- [Architecture](../docs/internals/architecture.md): "The C API layer", "The undo list", and "The plate set".
- [One view](../docs/internals/one-view.md): the plan of the main window that the core serves.
- `include/zslice-app.h` (about 2800 lines) and `include/zslice.h`.
- [C API](../docs/embedding/c.md), [Zig API](../docs/embedding/zig.md), [Overview](../docs/embedding/overview.md).
- User pages for the behavior: [Click a line](../docs/user/lines.md), [Place the parts](../docs/user/parts.md), [Plates and files](../docs/user/plates.md), [Undo and history](../docs/user/history.md), [Check the print](../docs/user/check.md).

## Build

1. `src/app.zig`: one `App` for one plate. States: `ZS_STATE_EMPTY` 0, `READY` 1, `SLICING` 2, `DONE` 3, `FAILED` 4. Events: `ZS_EVENT_PROGRESS` 1, `SLICED` 2, `FAILED` 3, `CANCELED` 4, `PLATES` 5, `SIMULATED` 6, `CHECKED` 7. The event callback runs on the worker thread.
2. `src/plate.zig` and `src/plate_job.zig`: the parts on the bed, each with its file mesh, place, and turn. Each part is its own engine job, and the G-code merges the layers of all parts by z. Settings for one part and modifier volumes (`src/part_settings.zig`).
3. Plate operations: open STL, OBJ, 3MF, STEP; arrange (rows, the largest first); smart placement that counts the islands of an orientation (`src/orient.zig`); lay flat ("Put this side on the bed"); scale; mirror; cut with a level plane, closed caps, and pegs (`src/cut.zig`); split into bodies; copy, cut, and paste of parts, plates, labels, support areas, layer changes, and setting values (`src/app/clipboard.zig`).
4. `src/app/plate_set.zig`: a `zs_set` owns one `zs_app` for each plate. The active plate slices first, then the other wanted plates, one at a time. A held change (`zs_set_changed_held`) waits for `zs_set_release`, so a drag slices once at the end. Native mode starts slices on core threads. Web mode (`zs_set_new_web`) slices on the calling thread when the worker calls `zs_set_step`.
5. `src/app/history.zig`: one undo list for each app. A shell calls `zs_app_history_commit` 400 ms after the last change (the core has no clock), and `zs_app_history_set_focus` with the setting of the focused editor. The edits of one setting are one step while its editor keeps the focus. A step keeps a snapshot of the plate, the texts of the three groups, the quality profile, and its "facts". The text of a step is the diff of its facts. Plates are not in an undo list: removing a plate cannot be undone.
6. `src/app/inspect.zig`, `inspect_picks.zig`, `feature_settings.zig`, `setting_effect.zig`: the real values of a clicked line (bead, planned and real speed, flow, time), the reasons in plain words, and the settings that change it. The line card and the settings panel use the same tables, so they agree.
7. `src/app/edits.zig`: edits of single lines (do not print it, change its plastic, add a drop). Each line has a key: the z of its layer, its feature, and its points rounded to 10 µm. The edits apply to each new slice.
8. `src/app/checks.zig`, `gap_advice.zig`, `measure.zig` (a least-squares circle fit for radii), `refine.zig` (repeated refinements offered on the next print), `sweep.zig` (which settings change time and cost the most).
9. `src/app/support_areas.zig`, `support_trees.zig`, `src/support_pick.zig`: support areas that add or block support, one-click support under the overhang at the pointer, and trees edited by hand.
10. `src/c_api/*.zig`: thin layers. Each export checks its pointers, calls the Zig API, and turns the Zig error into a status. Each function that changes the state notes the change for the undo list. Text results use one rule: call once with a NULL buffer for the length, then again with a buffer.

## The C API shape

The prefixes of `zslice-app.h`, with their rough counts: `zs_app_` (about 160), `zs_view_` (about 100), `zs_set_` (about 26), `zs_bambu_`, `zs_printer_`, `zs_printers_`, `zs_rtsp_`, `zs_mqtt_`, `zs_paint_`, `zs_discovery_`, `zs_farm_`, `zs_gcode_`, `zs_session_`, `zs_setting_`, `zs_history_`, `zs_project_`, `zs_label_`, `zs_clipboard_`, `zs_cura_`, `zs_license_`. The sections of the header: the model, settings, the status of a printer, slicing, the result, inspect a path, settings for some layers, the plate, paint, labels, the filaments of the plate, saved state, the 3D view, a print view, the plates in one view, the 2D view and the steps along the print, comparison with Cura, printdeck.yml projects, the plate set, licenses, the printer library, printer discovery, and the farm.

## Rules that matter

- One thread: call each `zs_app_*` from the UI thread. Copy each event to the UI thread. On each event, read `zs_app_state`: an event from an old slice can come after a new slice starts.
- A slice after each change: `zs_app_request_slice` (or `zs_set_changed` in a set) stops the old slice and starts a new one.
- A new change stops a slice that runs. A slice keeps the work of the last slice (the memos, part 16) and makes again only what the change touches.
- Licenses: `zs_license_count` and `zs_license_get` give zslice and each component with full texts. A shell adds the libraries that only it links.
- The selection stays on the same kind of line when a new slice moves it.

## Lessons

- **History steps are snapshots.** Each step after a plate change first wrote a full 3MF with deflate on the UI thread: 297 ms for a 3DBenchy after each move. A snapshot keeps each mesh raw in its own zip entry, and a move changes only the transforms: 11 ms.
- **Settle parts in the core.** A part fell over only when a shell called the settle after the Turn tool. Now the core settles each part that gets a new orientation from a load, a placement, smart placement, or a reset, while support is off.
- `zs_set_app` must not wait for the lock of the set while a slice thread holds it (it waited about 12 ms on the Mac).
- Keep each Support edit as its own history step. Keep a drag of a part setting in the search as one step.
- Keep the printer of each plate in the core and in the project file.
- After a cut that leaves no free place, arrange the plate. `zs_app_plate_fits` says when parts still do not fit.
- Never show an empty view for a focus on a setting with no lines on the plate. `zs_view_focus` returns 0, and the shell says so.
- Warn of a part off the bed only for a real fault.

## Acceptance checks

1. A C program opens an STL, slices it with the app API, and gets `ZS_EVENT_SLICED`, the stats, the layer paths, and the G-code.
2. Undo and redo of a move, a setting, and a support edit give the same plate and the same G-code.
3. A plate set of three plates slices the active plate first, then the others, and a change of the active plate stops a background slice.
4. A click on a line gives its values, its reasons, and its settings. The same settings show for that feature in the settings panel.
5. A line edit (do not print) stays after a change of the fan speed.
6. The web worker, the GTK app, the Mac app, and the Windows app call the same functions for the same behavior.
