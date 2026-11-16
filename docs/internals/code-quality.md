# Code quality plan

This page lists the parts of the code that are large, tangled, duplicated, badly named, or not tested. The list is in order of value: the first items help a reader most. A change in this plan does not change the behavior. The G-code stays the same byte for byte, and the app looks and acts the same.

Mark an item done when its commit is in `master`. Add an item when you find a problem that you do not fix at once.

## 1. The app core: `src/app.zig`

`src/app.zig` has 1840 lines with six concerns in one file:

- the state of the app, the plate, and the slice worker;
- the toolpaths of a slice, the layer paths, and the pick of a path;
- the inspection of a path (the text and the settings);
- the effect of each setting on the preview;
- the setting descriptions for a settings panel (units, sliders, defaults, labels);
- the licenses.

Plan:

- [ ] Move each concern to its own file in `src/app/`. `src/app.zig` keeps `App` and the state, and exports the names that `c_api.zig` and `render/view.zig` use.
- [ ] Compute the length of a path in one function. `featureStats` and `inspect` have the same loop.
- [ ] Move logic out of `c_api.zig` into the core: the part of a path (`zs_app_part_of_path`), the clear of the marks, and the name of a part.

## 2. The GTK settings panel: `linux/src/ui/settings-panel.c`

2100 lines. It has the setting editors (entries, sliders, the drag on a label), the inspector page, the part page, and the settings browser.

- [ ] Split it into `setting-editor.c` (one editor for one setting), `inspector.c` (the "Selected" page), `part-page.c` (the page of a part), and `settings-browser.c` (the "Settings" page). Each file gets a header that documents its interface.
- [ ] Correct the header comment of `settings-panel.h`. It describes one page for each group, which the panel no longer has.

## 3. The GTK preview: `linux/src/ui/preview.c`

950 lines: the 2D drawing, the replay and scrub bar, the color modes, and the keyboard navigation.

- [ ] Move the keyboard navigation to its own unit.
- [ ] Move the replay and the scrub bar to their own unit.
- [ ] Later: the navigation decides which line comes next (`segments_of`, `nearest_on_layer`, `layer_of_path`). By the rule of `docs/app/README.md`, this decision goes in the core, so that each shell behaves the same. The core already has `App.layerOfPath`. This needs new C API functions.

## 4. The GTK window: `linux/src/ui/window.c`

690 lines: the status bar, the file dialogs (open, export, save the plate), the send to a printer, and the layout.

- [ ] Move the send to a printer and the printer poll to their own unit.

## 5. The C API: `src/c_api.zig`

1140 lines with three APIs: the slicer (`zslice.h`), the app (`zslice-app.h`), and the 3D view.

- [ ] Split it into one file for each header part. The exported symbols do not change.

## 6. Tests

These paths matter and have few or no tests:

- [ ] Settings validation: `Settings.set` with a bad value, a value out of the limits, an unknown name; `resolve` with bad combinations.
- [ ] 3MF in the app: a bad file keeps the old plate; overrides that the version does not know are left out.
- [ ] The plate in the app: rotate, arrange, clear, the name of the plate.
- [ ] Support marks: the z tolerance, the radius, replace and remove.
- [ ] Profiles in the app: `applyProfile` with a bad text keeps the settings; `writeState` and `applyProfile` give the same settings back; `resetGroup`.
- [ ] Combing: a travel with combing on does not cross a wall.

## 7. Consistency

- [ ] Each source file that uses a source in `REFERENCES.md` names it in its header comment.
- [ ] One list of the `ZSLICE_*` test hooks of the GTK shell, in `docs/app/README.md`.
- [ ] No TODO without an entry in `ROADMAP.md`. (Now: no TODO in the code.)

## 8. Build hygiene

- [ ] No warnings from `zig build`, `zig build test`, `zig build wasm`, and `ninja -C linux/build` (meson `warning_level=2`).

## Later: files that the slicing work changes now

These files change often for performance work. Change them only in small, safe steps.

- `src/layer.zig` (1690 lines) and `src/engine.zig` (1200 lines) are the largest stage files.
- `linux/src/ui/view3d.c` (550 lines) has the 3D view widget, the drag of a part, and the test hooks. It changes on `master` now. Split it after that work.
