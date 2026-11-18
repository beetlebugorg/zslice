# The zslice app

The zslice app has one core and one native shell for each platform:

| Platform | Shell | Folder | Status |
|---|---|---|---|
| Linux | GTK4, C | `linux/` | Works |
| Web | HTML, JavaScript, WebGL2 | `web/app/` | First version: see `web/app/README.md` |
| macOS | SwiftUI, AppKit, Metal | `macos/` | First version: see [the macOS app](../internals/macos.md) |
| iOS | SwiftUI | `ios/` | Planned |
| Windows | Win32, C++ | `windows/` | Planned |
| Android | Kotlin | `android/` | Planned |

## The rule: logic in the core, widgets in the shell

The app core (`src/app.zig`, C API in `include/zslice-app.h`) has all the app logic: the model, the settings, the slice job, the result, the layer paths for the preview, and the license list.

A shell does only three things:

1. It draws native widgets.
2. It reads and writes files. The core does no file I/O, so it works in a sandbox (iOS, a browser).
3. It moves core events to its UI thread.

If a shell needs a decision (when to slice again, what a setting means, how to format a value from the core), the decision goes in the core, and each shell calls it. Then all shells behave the same.

## The contract

Read `include/zslice-app.h` first. The main points:

- **One thread.** Call each `zs_app_*` function from the UI thread.
- **Events come from a worker thread.** The callback of `zs_app_new` runs on the slice thread. Copy the event and post it to the UI thread: `g_idle_add` (GTK), `DispatchQueue.main.async` (Swift), `PostMessage` (Win32), `Handler.post` (Android).
- **The state is the truth.** On each event, read `zs_app_state`. An event from an old slice can arrive after a new slice starts.
- **Plates are in the core.** A shell with more than one plate keeps one `zs_set` (`zs_set_new`). Its callback gets the plate of each event, and `ZS_EVENT_PLATES` when the list or a status changes. Call the `zs_app_*` functions on the app of the active plate (`zs_set_app`), and `zs_set_changed` after each change in place of `zs_app_request_slice`. See "The plate set" in docs/internals/architecture.md.
- **Slice after each change.** After the user changes a setting or opens a model, call `zs_app_request_slice`. It stops the old slice and starts a new one. A slice of a typical part takes less than a second, so the preview follows the settings.
- **Settings panel from data.** `zs_setting_count` and `zs_setting_get_info` give each setting with its group, section, label, help text, kind, and choices. Build the panel from these. Do not list settings in the shell.
- **Preview one layer at a time.** `zs_app_layer_paths` makes the paths of one layer in a few milliseconds. Keep only the layers on the screen.
- **Undo in the core.** The core keeps the undo list and notes each change. The shell calls `zs_app_history_commit` 400 ms after the last change, tells the core which setting editor has the focus (`zs_app_history_set_focus`), and draws the history. See [the undo list](../internals/architecture.md#the-undo-list).
- **Licenses.** `zs_license_count` and `zs_license_get` give zslice and the components in the core, with full texts. A shell adds the libraries that only it links (for example GTK), and shows all of them in a Licenses screen.

## The printer library and the printer search

The core has the printer library (`zs_printers_*`) and the packets of the printer search (`zs_discovery_*`). A shell draws the picker from them; the facts, the search, the match of a printer on the network, and the machine profile of a model come from the core. Native builds embed the library. The web app loads `printers.txt` when the picker opens. The core does no network I/O: the shell sends the mDNS query and gives the answers to the core, and it asks a new printer for `/api/version` (or the Klipper toolhead). A browser cannot do this, so the web picker asks for an address.

The bed model of the current printer comes from the library too. `zs_printers_find_machine` finds the model of the machine profile (`machine.model`, else a `machine.name` that is the title of a model), and `zs_printers_bed` names its two files in the bed folder. The shell reads the files and gives the bytes to `zs_view_set_bed`; the core reads the mesh and the PNG, places the bed, and sends it to the GPU once. The GTK shell reads the files from `share/zslice/beds` (installed by meson), or from `src/printers/beds` of the source tree, or from `$ZSLICE_BEDS_DIR` (see `ui/bed-model.h`). The web app fetches them from `beds/`. Both pickers draw a flat texture (`zs_printer_bed.flat`) on the plate of the build volume.

## The 3D view

The core draws the 3D view of a slice (`src/render/`). The shell gives a native surface, and calls the `zs_view_*` functions of `include/zslice-app.h`:

1. Make a native surface for the view widget: on Linux, a Wayland subsurface under the window (`linux/src/ui/native-surface.c`); later an `HWND` on Windows and an `ANativeWindow` on Android. On macOS and in a browser, the shell draws the frame data itself (`ZS_SURFACE_FRAME`), so the core needs no surface.
2. `zs_view_new` with the surface and the size in pixels.
3. After `ZS_EVENT_SLICED`: `zs_view_load`.
4. On a change (layer, drag, scroll, size): call `zs_view_set_layer`, `zs_view_orbit`, `zs_view_zoom`, or `zs_view_resize`, then `zs_view_draw` once. Draw only after a change, so that a static view uses no CPU.

The goal of the view is to look like the finished print. Each segment is a bead with the real cross section (a flat top and bottom, round sides), round ends, the width of the plastic that is really deposited, the cooled size (the shrinkage compensation removed), and the filament color (`filament.color`). `zs_view_set_mode` switches to one color for each feature.

The backend is Vulkan on Linux (and later Windows and Android). In a browser and on macOS, the frame backend (`src/render/web.zig`) keeps the frame data in the memory of the core, and the shell draws it: the page with WebGL2 (see `web/app/README.md`), and the macOS app with Metal (see [the macOS app](../internals/macos.md)). The core loads the Vulkan loader at run time, so a shell does not link it. Without Vulkan, `zs_view_new` returns `ZS_NOT_SUPPORTED`, and the shell shows the 2D view only.

On Linux, the GTK window is transparent, and the view widget draws nothing: the subsurface shows through it. Each other part of the window must paint its whole area (use padding, not margins).

The GTK shell has options for development and tests. See [Test hooks of the GTK shell](#test-hooks-of-the-gtk-shell).

## Inspect a path

A click on a path in a view picks it: `zs_app_pick_layer` in a 2D layer view (a point in mm), and `zs_view_pick` in the 3D view (a pixel). `zs_app_inspect` then gives what the path is, its real values (the bead width, the planned and the real speed, the flow, the time span), the reasons for them in plain words, and the names of the settings that change it. The shell shows the text and an editor for each setting, and highlights the path (`zs_view_highlight`).

After a new slice, the path numbers change. The GTK shell keeps the layer and a point of the selected path, and picks the path at that place again, so that the inspector stays on the same line after a setting changes.

A shell with no access to the app on its UI thread (the web app: the app is in a worker) uses the loaded view instead. `zs_view_pick_layer` picks in a 2D view, `zs_view_layer_beads`, `zs_view_layer_marks`, and `zs_view_outlines` give the data of one layer to draw, and `zs_view_step`, `zs_view_nearest_on_layer`, and `zs_view_segment_at_time` give the steps of the keys h, j, k, and l. A pick uses the pick index of the view, so it stays under a millisecond on a plate of many parts.

## Replay

`zs_view_set_time(view, t)` shows the print as it is t seconds after the start: each bead that is done, and the part of the bead that the nozzle is printing. The times come from the G-code emitter, with the cooling slow-down, so the replay follows the G-code. A shell moves t on each frame while it plays (GTK: a frame-clock tick callback, at a speed of 1x to 100x), and shows `zs_view_layer_at_time` on its layer slider. `zs_view_set_layer` ends the replay.

## The GTK shell

The GTK shell is in `linux/src`. Each `.c` file has a header that explains its interface:

| Folder | File | What it has |
|---|---|---|
| | `main.c` | The application, and a watchdog of the UI thread |
| `model/` | `app-model` | The core as a GObject: signals on the UI thread, the saved state |
| `prefs/` | `printers` | The printers of the user, and the app settings file |
| `net/` | `printer-link` | HTTP and USB connections to printers |
| | `discovery` | The search of the network for printers (mDNS), with the packets of the core |
| | `project-source` | The files of a printdeck.yml project: a folder, or a public GitHub repository |
| `ui/` | `window` | The main window: the header bar, the file dialogs, the send to a printer, and the status bar |
| | `preview` | The 2D and 3D preview with the tool strip, the layer slider, the replay, the measure readout, and the keyboard navigation |
| | `layer-draw` | The cairo drawing of one layer in the 2D view |
| | `toolpath-nav` | The next segment and the nearest line, for the keyboard navigation |
| | `layer-range` | The slider with two knobs for the layers that show |
| | `view3d` | The widget of the 3D view, the drag of a part, and the rings of the Turn tool |
| | `bed-model` | The bed model of the current printer in the 3D view: finds the bed folder and reads the files |
| | `native-surface` | The Wayland subsurface for the 3D view |
| | `float` | The cards over the view: their places in the overlay of the preview, and the drag of their head |
| | `search` | The settings search (`/`): settings with live controls, and actions |
| | `line-card` | The card of a selected line: its numbers, and the settings that matter for it |
| | `part-card` | The card of a selected part: its actions and its own settings |
| | `shortcuts` | The sheet of the keyboard shortcuts (`?`): one table of the keys |
| | `settings-panel` | The panel (a drawer: hidden, over the view, or pinned) with its pages: Settings, Selected, History, and Project |
| | `inspector` | The "Selected" page: the values of a line and the settings that change it |
| | `project-page` | The "Project" page: a printdeck.yml project, its plates and parts, and the status of each plate |
| | `part-page` | The page of a part: its place, turn, and scale, and the placement |
| | `settings-browser` | The "Settings" page: all settings in three columns |
| | `setting-row` | One setting as a row of a grid |
| | `setting-editor` | The editor of one setting, and the text of a value |
| | `widgets` | Small widget helpers that the pages share |
| | `printer-picker` | The printer picker: the first-start onboarding and "Add a printer…" |
| | `preferences`, `licenses` | The Preferences and the Licenses windows |
| | `colors.h` | The feature colors |

## Test hooks of the GTK shell

These environment variables change the start of the GTK shell, for development, tests, and screenshots. They are the only hidden options of the shell. The last column names the file that reads each one.

| Variable | Effect | Read in |
|---|---|---|
| `ZSLICE_BEDS_DIR=dir` | Reads the bed models of the printers from `dir`. | `ui/bed-model.c` |
| `ZSLICE_STATE_DIR=dir` | Keeps the settings and the printers in `dir`, not in `~/.config/zslice`. | `prefs/printers.c` |
| `ZSLICE_NON_UNIQUE=1` | Starts a separate instance. Without it, a second start sends its file to the running instance. | `main.c` |
| `ZSLICE_TEST_HANG=s` | Stops the UI thread for `s` seconds, 3 s after the start, to test the watchdog. | `main.c` |
| `ZSLICE_VIEW=2d` or `3d` | Opens the 2D or the 3D view. | `ui/preview.c` |
| `ZSLICE_COLORS=n` | Starts with the color mode `n` (`enum zs_view_mode`). | `ui/preview.c` |
| `ZSLICE_LAYERS=lo,hi` | Shows the layers from `lo` to `hi` after the first slice. | `ui/preview.c` |
| `ZSLICE_TIME=t` | Shows the replay at `t` seconds before the first frame. | `ui/view3d.c` |
| `ZSLICE_MEASURE=x0,y0,x1,y1` | Picks the Measure tool, and clicks two points at the pixels x0, y0 and x1, y1 of the view that shows (2D or 3D), 1 s after the first slice. | `ui/preview.c` |
| `ZSLICE_PICK=x,y` | Picks the path at the pixel x, y of the 3D view after the first load. | `ui/view3d.c` |
| `ZSLICE_DOUBLE_CLICK=x,y` | A double click at the pixel x, y of the 3D view, 1 s after the first slice: on a side of a part, the view turns to face that side; elsewhere, the view resets. | `ui/view3d.c` |
| `ZSLICE_COPY_FOR_AI=1` | With `ZSLICE_PICK`: runs "Copy for AI" on the picked line, and prints the report to the log (with no input event, Wayland can refuse the clipboard). | `ui/view3d.c` |
| `ZSLICE_GAPS=1` | Turns the gaps view on. `ZSLICE_GAP=N` then selects gap N of the top layer after a slice. | `ui/view3d.c` |
| `ZSLICE_SETTING_LIST=1` | With `ZSLICE_SETTING`: shows the settings list of its section, not its detail page. | `ui/settings-browser.c` |
| `ZSLICE_PROFILE=up` or `down` | With `ZSLICE_PICK`: runs "New profile from here up" (or down) on the picked line. `ZSLICE_PROFILE_SET=name=value` then changes one setting in it. | `ui/view3d.c` |
| `ZSLICE_PART=i` | Selects part `i` of the plate after the first load. | `ui/view3d.c` |
| `ZSLICE_RING_DRAG=x0,y0,x1,y1` or `auto` | With `ZSLICE_PART`: picks the Turn tool, and drags a ring of the part from the pixel x0, y0 to x1, y1 (`auto`: from the point of the rings at +X to the point at +Y) of the 3D view in 12 steps, 1 s after the first slice. The log gives the axis and the turn. | `ui/view3d.c` |
| `ZSLICE_SUPPORT_DO=steps` | Picks the Support tool 1 s after the first slice, and runs one step each 600 ms, as the mouse and the keys would. Steps, with `;` between them: `orbit dx dy`, `click x y`, `shift x y` (a click with Shift), `key Return` (a key by its GDK name), `drag i j x y` (point j of area i to x, y), `kind k` (button k of the card), `see 0` or `see 1`, `undo`, `redo`. x, y are points of the 3D view. The log gives the areas, their points on the screen, the history, and the filament after each step. | `ui/support-tool.c` |
| `ZSLICE_ZOOM=z` | Starts the 3D view at the zoom `z` (for example 0.3: nearer). | `ui/view3d.c` |
| `ZSLICE_ZOOM_AT=x,y,n` | Zooms `n` wheel steps toward the pixel x, y after the first load. | `ui/view3d.c` |
| `ZSLICE_INSPECT_FOCUS=name` | Puts the focus on the row of the setting `name` in the inspector after the first selection. | `ui/inspector.c` |
| `ZSLICE_SETTING=name` | Opens the Settings page at the setting `name`. | `ui/settings-browser.c` |
| `ZSLICE_PROJECT=dir` or `owner/repo` | Opens the printdeck.yml project of a folder or of a GitHub repository at the start, and shows the Project page. `ZSLICE_PROJECT_PLATE=n` then opens plate n (from 1), also for the project of the last session. | `ui/project-page.c` |
| `ZSLICE_PROJECT_DO=steps` | Changes the widgets of the Project page 3 s after the start, one step each second, as a click would. Steps, with `;` between them: `status 1 printed`, `count 2 0`, `check 2 off`, `scroll 600`, `sent`, `set machine.max_height 300`, `end`, `close`. | `ui/project-page.c` |
| `ZSLICE_ACTION=name` | Runs an action 1.5 s after the first slice, as a click would. The name is a detailed action name, for example `win.search-part(int64 0)` (the search of part 0), `win.show-page('history')`, or `win.shortcuts`. | `ui/window.c` |
| `ZSLICE_UNDO_TEST=1` | Changes the infill, undoes and redoes, moves part 0 and undoes the move, edits the wall count with the focus on its editor, goes to step 1, and clears the history after it, one step each second. The log gives the values and the steps of the history. | `ui/window.c` |
| `ZSLICE_PLATE_TEST=file` | Adds a plate and puts the model `file` on it, adds an empty plate and removes it, goes to plate 1 and back, and removes the plate with the file, one step each second. The log gives the plates of the set (zs_set_plate_info). | `ui/window.c` |
| `ZSLICE_PREFS=1` | Opens Preferences 1.5 s after the start. With it, `ZSLICE_GET_KEY=1` presses "Get a key" for the current printer. | `ui/window.c`, `ui/preferences.c` |
| `ZSLICE_PICKER=1` | Opens the printer picker at the start. With it: `ZSLICE_PICKER_QUERY=text` types a search, `ZSLICE_PICKER_MODEL=id` selects a model, `ZSLICE_PICKER_FOUND=n` selects printer n of the network when the search ends, and `ZSLICE_PICKER_STEP=2` (the second step) or `add` (add the printer at once). | `ui/printer-picker.c` |

To run the app for a check without your own settings:

```sh
ZSLICE_STATE_DIR=$(mktemp -d) ZSLICE_NON_UNIQUE=1 ZSLICE_VIEW=2d linux/build/zslice-gtk part.stl
```

## The preview colors

All shells use the same colors, in the order of `enum zs_feature`:

| Feature | Color |
|---|---|
| Outer wall | `#d9480f` |
| Inner wall | `#f59f00` |
| Skin | `#1c7ed6` |
| Infill | `#2b8a3e` |
| Ironing | `#ae3ec9` |
| Skirt and brim | `#8d6e63` |
| Support | `#adb5bd` |
| Support interface | `#495057` |
| Slope smoothing | `#0ca6ae` |
| Slope ironing | `#82c91e` |
| Bridge | `#66ccf2` |

## Add a shell

1. Build the core for the platform: `zig build lib -Dtarget=<target> -Doptimize=ReleaseFast`. It makes `libzslice.a` and the two headers.
2. Wrap `zs_set` (or one `zs_app`) in one object of the platform (a GObject, an ObservableObject, a ViewModel) that owns the core and moves the events to the UI thread. See `linux/src/model/app-model.c`.
3. Build the window: open, export, the settings panel, the preview with a layer slider, a status bar, and a Licenses screen.
4. Use the GTK shell as the reference for the behavior.

The structure follows the Lookout Marine app (a Zig core with native shells for each platform, by the same author).
