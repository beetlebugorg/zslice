# 07. The app core and the C API

## Goal

Build the app core: all logic of the zslice app, behind one C API, so that each shell only draws widgets, reads and writes files, and moves events to its UI thread. It has the plate and its parts, the plate set, the background slice, the undo list and the history, the inspection of a line, the settings descriptions, the checks, and the edits of lines. Then the 3D view (part 08) and the shells (parts 09 to 12) build on it.

## Read first

- [The app](../docs/app/README.md): the rule and the contract. Read it before any shell work.
- [Architecture](../docs/internals/architecture.md): "The C API layer", "The undo list", and "The plate set".
- [One view](../docs/internals/one-view.md): the plan of the main window that the core serves.
- `include/zslice-app.h` (about 3100 lines) and `include/zslice.h`.
- [Place the parts](../docs/user/parts.md) for the transform tool, and [Import a model from a model page](../docs/internals/model-import.md) for the import contract.
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
10. Calibration prints (`src/calib.zig`, `zs_app_calibration_add`, `zs_app_calibration_get`). Each test is a new plate with a test part that the core makes, and its value varies by layer range or by part, so each value shows in the settings of the plate. The tests are in the header of `calib.zig`: a temperature tower (blocks of 5 °C, the hottest at the bottom), a retraction test (two pillars, bands of 5 mm), a flow test (cubes from 80 % to 120 %), and a pressure advance tower (a square with one wall, bands of 4 mm, after the tuning tower of Klipper). A printer with a tool changer also gets a label with each value. The card of the test says how to read the print, and its buttons set the chosen value on each plate.
11. Links that open a model (`src/open_link.zig`, the `zs_link_*` calls of `include/zslice.h`). [Links that open a model](../docs/internals/open-links.md) is the contract. The core checks the link, each redirect, the head of the answer, and the file name. The shell resolves the host, refuses a local address, and downloads. `zs_link_url` and `zs_link_set_url` give the URL to a language that cannot import a C array field.
12. Draft slices (`zs_app_set_draft`, parts 08 and 16): while the last slice is a draft, `zs_app_gcode` and `zs_app_bambu_file` give `ZS_NO_RESULT`.
13. The transform of a part. A part has a lift (`Part.z`): over 0 it floats, under 0 it sinks into the bed. A turn about X or Y goes about the axes of the bed, also for a part with a turn about Z. `zs_app_part_set_angles` sets the turns about X, Y, and Z. `zs_part` gives the lift and the angles. `zs_part_snap` snaps a moving footprint to the edges and centers of the other parts and to the center of the bed (`src/part_snap.zig`), and gives the guide lines.
14. A part that does not fit. `zs_app_part_fit` and `zs_app_part_fit_text` give the cause and the sizes ("The part is 130 mm high, and the printer reaches 80 mm."). The part slices, so the view shows it. `zs_app_plate_printable` gives the reason, and the calls that make a file to print refuse the plate. The export of all plates and the send of all plates leave that plate out and say so. `zs_app_failure_name` (an export of `src/c_api/app.zig`, not in the header) gives the name of the error of a failed slice.
15. `Set.spill` (`zs_set_spill`): while the parts of a plate do not fit its bed, its last part goes to a new plate with the same settings. An import of many files calls it once after the files load.
16. The import from a model page (`src/model_import.zig`, the `zs_import_*` calls of `include/zslice.h`). The core reads the address of a Printables model or a Thingiverse thing. `zs_import_page_text(site)` gives the text for the user: it names the site, and says to click "Download all" there and open the ZIP file in zslice. The core lists the files of a ZIP file of a model (`zipfile.directory`, then `extract` for each checked file). The list groups the files by kind (3MF, STL, STEP, OBJ, other), checks the files to load first, and counts the plates of a 3MF file. The core makes no request to a site, and no app calls the API of a site (see the lesson below).
17. The waste (`zs_app_waste`, part 05), the Speed section (`zs_speed_*`, `zs_app_speed_state`, `zs_app_speed_set`, part 02), and the regions of a body (`zs_app_region_set`, part 05).
18. The selection model (`src/app/selection.zig`, the `zs_sel_*` calls, [Selection and focus](../docs/internals/selection.md)): the active plate, the selected parts by stable id, the line by its key, the hover, the tool, and the camera target. A generation orders the requests and the replies, and the pick tests a moved part at its current place.
19. `src/c_api/*.zig`: thin layers. Each export checks its pointers, calls the Zig API, and turns the Zig error into a status. Each function that changes the state notes the change for the undo list. Text results use one rule: call once with a NULL buffer for the length, then again with a buffer.

## The C API shape

The prefixes of `zslice-app.h` (about 3100 lines), with their rough counts: `zs_app_` (about 220), `zs_view_` (about 120), `zs_set_` (about 30), `zs_quality_`, `zs_bambu_`, `zs_printer_`, `zs_printers_`, `zs_rtsp_`, `zs_mqtt_`, `zs_paint_`, `zs_discovery_`, `zs_farm_`, `zs_gcode_`, `zs_session_`, `zs_setting_`, `zs_history_`, `zs_project_`, `zs_label_`, `zs_clipboard_`, `zs_cura_`, `zs_license_`, `zs_speed_`, `zs_part_`. `zslice.h` also has `zs_link_` and `zs_import_`. The sections of the header: the model, settings, the status of a printer, slicing, the result, inspect a path, settings for some layers, the plate, paint, labels, the filaments of the plate, saved state, the 3D view, a print view, the plates in one view, the 2D view and the steps along the print, comparison with Cura, printdeck.yml projects, the plate set, licenses, the printer library, printer discovery, and the farm.

## Rules that matter

- One thread: call each `zs_app_*` from the UI thread. Copy each event to the UI thread. On each event, read `zs_app_state`: an event from an old slice can come after a new slice starts.
- A slice after each change: `zs_app_request_slice` (or `zs_set_changed` in a set) stops the old slice and starts a new one.
- A new change stops a slice that runs. A slice keeps the work of the last slice (the memos, part 16) and makes again only what the change touches.
- Licenses: `zs_license_count` and `zs_license_get` give zslice and each component with full texts. A shell adds the libraries that only it links.
- The selection stays on the same kind of line when a new slice moves it.
- **One count of problems.** After each slice, read the check once. The Check button of the tool strip shows the count of the issues with a severity of a warning or more. The badge of the print card says "N to check" with the same count. A slice in progress clears the count.
- **A history step keeps its time on a commit with no change.** The apps commit on a timer and after an undo. The history button of each app counts the changes since the last open or save from the times of the steps.
- An import from a model page never starts a print. The list of files is the question before the load.
- No app calls the API of a model site. A direct link to one file (an https URL of a model file, or a `zslice://open?file=` link) still downloads with the rules of the links: the user chose that one file.
- A link refuses a zslice project, opens the model on a new plate if the active plate has parts, and never starts a print. In the GTK, Mac, and Windows apps, a file or a link from outside waits until the session is back.
- A part has a stable id (`plate.Part.id`). It stays through moves, plate moves, undo, redo, and a reload (the `partid` lines of the 3MF metadata). A copy gets a new id. Never keep a part index across a call.

## Lessons

- **History steps are snapshots.** Each step after a plate change first wrote a full 3MF with deflate on the UI thread: 297 ms for a 3DBenchy after each move. A snapshot keeps each mesh raw in its own zip entry, and a move changes only the transforms: 11 ms.
- **Settle parts in the core.** A part fell over only when a shell called the settle after the Turn tool. Now the core settles each part that gets a new orientation from a load, a placement, smart placement, or a reset, while support is off.
- `zs_set_app` must not wait for the lock of the set while a slice thread holds it (it waited about 12 ms on the Mac).
- Keep each Support edit as its own history step. Keep a drag of a part setting in the search as one step.
- **Each user edit must be in the snapshot.** A step compares the settings and the 3MF of the plate. The support marks were in neither, so a mark made no step: Undo went to the step before it, and a restart lost the mark. Write each kind of user edit as a line of the plate 3MF (`mark` lines now), and test undo, redo, and a reload for it.
- Keep the printer of each plate in the core and in the project file.
- After a cut that leaves no free place, arrange the plate. `zs_app_plate_fits` says when parts still do not fit.
- Never show an empty view for a focus on a setting with no lines on the plate. `zs_view_focus` returns 0, and the shell says so.
- Warn of a part off the bed only for a real fault.
- **Count the same problems on the Check button and the print card.** The button listed every issue of the check. The badge ran a test of its own (an area over air, only with support off). With support on, the button had issues and the badge had none.
- **Keep the time of a step on a commit with no change.** A commit with no change gave the step a new time. After a save, a step then got a time after the save, and the badge counted a change that did not happen.
- **Say why a part does not fit, with its sizes.** The apps had one text for a part that is too large, and it said "higher than the printer" also when the bed was the problem.
- **Slice a part that does not fit, and keep it from printing.** A part higher than the printer now slices, so the view shows it, and the check names it.
- **Turn about the axes of the bed.** A turn about X or Y went about the axes of the part, so a part with a turn about Z turned the wrong way.
- **Call no private API of a site, and obey the terms of each site.** The import read the file list and the download links of Printables from its private GraphQL API (`print(id)` and the `getDownloadLink` mutation). The terms of the Prusa sites forbid automated extraction. The core, the C API, and the GTK app lost that code. A model page now gets the text of `zs_import_page_text` and an Open the page button, as Thingiverse did. The result codes 4 and 9 are free, and the numbers of the other codes stay.
- **Give a C string field an accessor call.** Swift imports no long C array as a field, so the Mac read the URL of a `zs_link` at offset 0 of the struct. `zs_link_url` and `zs_link_set_url` keep the layout of the struct free to change.
- **Name a part by a stable id.** A selection by index named another part after a delete, a plate change, or an undo. Each part now has an id, and the model drops an id that left the plate.

## Acceptance checks

1. A C program opens an STL, slices it with the app API, and gets `ZS_EVENT_SLICED`, the stats, the layer paths, and the G-code.
2. Undo and redo of a move, a setting, and a support edit give the same plate and the same G-code.
3. A plate set of three plates slices the active plate first, then the others, and a change of the active plate stops a background slice.
4. A click on a line gives its values, its reasons, and its settings. The same settings show for that feature in the settings panel.
5. A line edit (do not print) stays after a change of the fan speed.
6. The web worker, the GTK app, the Mac app, and the Windows app call the same functions for the same behavior.
7. `zig build test` passes the tests of `open_link.zig`: the refused URLs (each form of an IP address, `.local`, another port), the names, and the redirects.
8. A calibration plate shows each step value in the settings of the plate, and a Use button sets that value on each plate.
9. The exact slice after a draft gives the G-code of a slice with no draft.
10. A part higher than the printer slices, `zs_app_plate_printable` refuses the plate, and the fit text names the height of the part and of the printer.
11. `zs_set_spill` puts the parts that do not fit one plate on new plates with the same settings.
12. The tests of `src/model_import.zig` and `src/c_api/import.zig` pass: the addresses, the text for a page of each site, the ZIP lists, and the plates of a 3MF file. A grep of `src`, `include`, and the shells finds no `graphql`, `getDownloadLink`, or `api.printables`.
13. The `selection:` and `selection api:` tests pass: a pick after a move, a late reply, a failed plate request, and ids through a delete, undo, redo, a save and a load, and a move to another plate.
