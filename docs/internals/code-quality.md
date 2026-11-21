# Code quality plan

This page lists the parts of the code that are large, tangled, duplicated, badly named, or not tested. The list is in order of value: the first items help a reader most. A change in this plan does not change the behavior. The G-code stays the same byte for byte, and the app looks and acts the same.

Mark an item done when its commit is in `main`. Add an item when you find a problem that you do not fix at once.

## 1. The app core: `src/app.zig`

`src/app.zig` had 1840 lines with six concerns in one file: the state of the app, the toolpaths and the pick, the inspection of a path, the effect of each setting on the preview, the setting descriptions, and the licenses.

- [x] Move each concern to its own file in `src/app/`. `src/app.zig` keeps `App` and the state, and exports the names that `c_api/` and `render/view.zig` use.
- [x] Compute the length of a path in one function (`Toolpaths.pathLength`). `featureStats` and `inspect` had the same loop.
- [x] Move logic out of the C API into the core: the part of a path (`App.partOfPath`), the clear of the marks (`App.clearMarks`), and the name of a part (a part keeps its name with a 0 at the end).
- [ ] `src/app.zig` grows again (5323 lines): the plates (`PlateSlot`, `selectPlate`, `addPlate`, `removePlate`; no shell uses them now that the plate set is `src/app/plate_set.zig`) and the part placement (`placePart`, `turnPart`, `scalePart`) are in `App`. Move the list of plates and the switch between them to `src/app/plates.zig`, and keep in `App` only the calls that also stop the worker and mark the plate as changed.
- [ ] `App.statusOf` is a second, shorter copy of `status` in `c_api.zig`. The failure event of a slice gives status 2 for some errors that `status` knows, for example `PartTooThin` (17). Use one function. This changes the status of some failure events, so it needs the approval of the owner.

## 2. The GTK settings panel: `linux/src/ui/settings-panel.c`

- [x] Split the 2100 lines into `setting-editor`, `setting-row`, `inspector`, `part-page`, `settings-browser`, and `widgets`, each with a header that documents its interface.
- [x] One function for the display text of a value (`zg_setting_display_value`). The editors and the browser had a copy each.
- [x] The "why" text uses the title of the inspection. It had its own list of the feature names.
- [x] Free the row of the browser detail. It leaked.
- [ ] `settings-browser.c` has a list of the feature and mark names (`feature_titles`). The core has the feature names in `app/feature_settings.zig`. A C API call for the names (features and marks) removes the copy.

## 3. The GTK preview: `linux/src/ui/preview.c`

- [x] Move the cairo drawing of a layer to `layer-draw.c`.
- [x] Move the search for the next line of the keyboard navigation to `toolpath-nav.c`.
- [ ] The keyboard navigation decides which line comes next. By the rule of `docs/app/README.md`, this decision goes in the core, so that each shell behaves the same. Move `toolpath-nav.c` into `app/toolpaths.zig` (with tests), and add C API calls for it. The core already has `Toolpaths.layerOfPath`.
- [ ] The plate bar (the tabs of the plates) is in `preview.c`. Move it to its own unit, as `layer-range.c`.
- [ ] The replay and the scrub bar can go to their own unit. They use many fields of the `Preview` struct, so they need a small interface first.

## 4. The GTK window: `linux/src/ui/window.c`

2590 lines: the status bar, the islands warning, the file dialogs, the send to a printer, the "all plates" send and export, and the layout.

- [ ] Move the printer chooser, the send, the poll of the printer state, and the "all plates" batch to a unit `printer-bar.c`. The window then places the widgets and calls the unit after each core event. This work waits until the plates feature is stable on `main`.
- [ ] Check `on_poll_info` after the window closes. `window_free` cancels the poll and frees the `Window`. If the HTTP layer calls the callback after a cancel, the callback reads freed memory.

## 5. The C API: `src/c_api.zig`

- [x] Split it into the slicer API (`c_api.zig`), the app API (`c_api/app.zig`), and the view API (`c_api/view.zig`). The exported symbols do not change.
- [ ] `zs_app_part_get` takes a `zs_app *`. It no longer changes the app, so it can take a `const zs_app *`. This changes the header, so it waits for the next change of the API.

## 6. Tests

- [x] Settings validation: the text forms of each kind, a bad value keeps the old one, the combinations that `resolve` rejects, the wall count from a wall thickness.
- [x] 3MF in the app: a bad file keeps the plate; an override of an unknown setting is left out.
- [x] The plate in the app: the name, a turn, the arrangement, remove, clear, and the part of a path.
- [x] Support marks: the layer, the radius, replace, remove, and clear.
- [x] Profiles in the app: the round trip of a group through `writeState` and `applyProfile`, a bad text that changes nothing, and `resetGroup`.
- [ ] Combing: `src/gcode.zig` now tests that the combing index gives the same answers as `combClear`. An end-to-end test is still missing: a slice with combing on has no travel that crosses a wall.
- [ ] The GTK shell has no unit tests. `toolpath-nav.c` and `layer-draw.c` have no widgets, so they can have tests first. A move of the navigation into the core (item 3) gives Zig tests.

## 7. Consistency

- [x] The source files that use a source in `docs/references/` name it in their header comment: `import_cura.zig`, `profile.zig`, `plate.zig`, and `native-surface.c` did not.
- [ ] `src/engine.zig` uses memoization (see `docs/references/papers-and-algorithms.md`) and does not name it in its header.
- [x] One list of the `ZSLICE_*` test hooks of the GTK shell, in `docs/app/README.md`.
- [x] No TODO without an entry in `ROADMAP.md`. There is no TODO in the code.
- [ ] `docs/internals/architecture.md` lists the main modules, with `app/`, `c_api/`, and `render/`. It does not list all modules: for example `print_sim.zig`, `cut.zig`, `label.zig`, `app/sim_print.zig`, and `render/cpu.zig` are missing.

## 8. Build hygiene

- [x] No warnings from `zig build`, `zig build test`, `zig build wasm`, and `ninja -C linux/build` (meson `warning_level=2`).
- [x] `zig fmt` for the files outside the slicing stages.
- [ ] `zig fmt --check` fails for `src/engine.zig` and `src/layer.zig`. Run `zig fmt` on them when no other branch changes them.

## Later: files that other work changes now

These files change often. Change them only in small, safe steps.

- `src/layer.zig` (4295 lines) and `src/engine.zig` (3610 lines) are the largest stage files.
- `linux/src/ui/view3d.c` (3125 lines) has the 3D view widget, the drag of a part, the context menu, the support marks, the multiple selection, and the test hooks. Split it when the work on the 3D view is stable: the context menu and the support marks first.
