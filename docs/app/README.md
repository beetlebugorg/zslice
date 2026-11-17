# The zslice app

The zslice app has one core and one native shell for each platform:

| Platform | Shell | Folder | Status |
|---|---|---|---|
| Linux | GTK4, C | `linux/` | Works |
| Web | HTML, JavaScript, WebGL2 | `web/app/` | First version: see `web/app/README.md` |
| macOS, iOS | SwiftUI | `apple/` | Planned |
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
- **Slice after each change.** After the user changes a setting or opens a model, call `zs_app_request_slice`. It stops the old slice and starts a new one. A slice of a typical part takes less than a second, so the preview follows the settings.
- **Settings panel from data.** `zs_setting_count` and `zs_setting_get_info` give each setting with its group, section, label, help text, kind, and choices. Build the panel from these. Do not list settings in the shell.
- **Preview one layer at a time.** `zs_app_layer_paths` makes the paths of one layer in a few milliseconds. Keep only the layers on the screen.
- **Licenses.** `zs_license_count` and `zs_license_get` give zslice and the components in the core, with full texts. A shell adds the libraries that only it links (for example GTK), and shows all of them in a Licenses screen.

## The 3D view

The core draws the 3D view of a slice (`src/render/`). The shell gives a native surface, and calls the `zs_view_*` functions of `include/zslice-app.h`:

1. Make a native surface for the view widget: on Linux, a Wayland subsurface under the window (`linux/src/ui/native-surface.c`); later a `CAMetalLayer` on Apple, an `HWND` on Windows, and an `ANativeWindow` on Android.
2. `zs_view_new` with the surface and the size in pixels.
3. After `ZS_EVENT_SLICED`: `zs_view_load`.
4. On a change (layer, drag, scroll, size): call `zs_view_set_layer`, `zs_view_orbit`, `zs_view_zoom`, or `zs_view_resize`, then `zs_view_draw` once. Draw only after a change, so that a static view uses no CPU.

The goal of the view is to look like the finished print. Each segment is a bead with the real cross section (a flat top and bottom, round sides), round ends, the width of the plastic that is really deposited, the cooled size (the shrinkage compensation removed), and the filament color (`filament.color`). `zs_view_set_mode` switches to one color for each feature.

The backend is Vulkan on Linux (and later Windows and Android), and Metal on Apple later. In a browser, the web backend (`src/render/web.zig`) keeps the frame data in wasm memory, and the page draws it with WebGL2 (see `web/app/README.md`). The core loads the Vulkan loader at run time, so a shell does not link it. Without Vulkan, `zs_view_new` returns `ZS_NOT_SUPPORTED`, and the shell shows the 2D view only.

On Linux, the GTK window is transparent, and the view widget draws nothing: the subsurface shows through it. Each other part of the window must paint its whole area (use padding, not margins).

The GTK shell has options for development and tests. See [Test hooks of the GTK shell](#test-hooks-of-the-gtk-shell).

## Inspect a path

A click on a path in a view picks it: `zs_app_pick_layer` in a 2D layer view (a point in mm), and `zs_view_pick` in the 3D view (a pixel). `zs_app_inspect` then gives what the path is, its real values (the bead width, the planned and the real speed, the flow, the time span), the reasons for them in plain words, and the names of the settings that change it. The shell shows the text and an editor for each setting, and highlights the path (`zs_view_highlight`).

After a new slice, the path numbers change. The GTK shell keeps the layer and a point of the selected path, and picks the path at that place again, so that the inspector stays on the same line after a setting changes.

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
| `ui/` | `window` | The main window: the header bar, the file dialogs, the send to a printer, and the status bar |
| | `preview` | The 2D and 3D preview with the layer slider, the replay, and the keyboard navigation |
| | `layer-draw` | The cairo drawing of one layer in the 2D view |
| | `toolpath-nav` | The next segment and the nearest line, for the keyboard navigation |
| | `layer-range` | The slider with two knobs for the layers that show |
| | `view3d` | The widget of the 3D view, and the drag of a part |
| | `native-surface` | The Wayland subsurface for the 3D view |
| | `settings-panel` | The panel with the two pages below |
| | `inspector` | The "Selected" page: the values of a line and the settings that change it |
| | `part-page` | The page of a part: its place, turn, and scale, and the placement |
| | `settings-browser` | The "Settings" page: all settings in three columns |
| | `setting-row` | One setting as a row of a grid |
| | `setting-editor` | The editor of one setting, and the text of a value |
| | `widgets` | Small widget helpers that the pages share |
| | `preferences`, `licenses` | The Preferences and the Licenses windows |
| | `colors.h` | The feature colors |

## Test hooks of the GTK shell

These environment variables change the start of the GTK shell, for development, tests, and screenshots. They are the only hidden options of the shell. The last column names the file that reads each one.

| Variable | Effect | Read in |
|---|---|---|
| `ZSLICE_STATE_DIR=dir` | Keeps the settings and the printers in `dir`, not in `~/.config/zslice`. | `prefs/printers.c` |
| `ZSLICE_NON_UNIQUE=1` | Starts a separate instance. Without it, a second start sends its file to the running instance. | `main.c` |
| `ZSLICE_TEST_HANG=s` | Stops the UI thread for `s` seconds, 3 s after the start, to test the watchdog. | `main.c` |
| `ZSLICE_VIEW=2d` or `3d` | Opens the 2D or the 3D view. | `ui/preview.c` |
| `ZSLICE_COLORS=n` | Starts with the color mode `n` (`enum zs_view_mode`). | `ui/preview.c` |
| `ZSLICE_LAYERS=lo,hi` | Shows the layers from `lo` to `hi` after the first slice. | `ui/preview.c` |
| `ZSLICE_TIME=t` | Shows the replay at `t` seconds before the first frame. | `ui/view3d.c` |
| `ZSLICE_PICK=x,y` | Picks the path at the pixel x, y of the 3D view after the first load. | `ui/view3d.c` |
| `ZSLICE_COPY_FOR_AI=1` | With `ZSLICE_PICK`: runs "Copy for AI" on the picked line, and prints the report to the log (with no input event, Wayland can refuse the clipboard). | `ui/view3d.c` |
| `ZSLICE_GAPS=1` | Turns the gaps view on. `ZSLICE_GAP=N` then selects gap N of the top layer after a slice. | `ui/view3d.c` |
| `ZSLICE_SETTING_LIST=1` | With `ZSLICE_SETTING`: shows the settings list of its section, not its detail page. | `ui/settings-browser.c` |
| `ZSLICE_PROFILE=up` or `down` | With `ZSLICE_PICK`: runs "New profile from here up" (or down) on the picked line. `ZSLICE_PROFILE_SET=name=value` then changes one setting in it. | `ui/view3d.c` |
| `ZSLICE_PART=i` | Selects part `i` of the plate after the first load. | `ui/view3d.c` |
| `ZSLICE_ZOOM=z` | Starts the 3D view at the zoom `z` (for example 0.3: nearer). | `ui/view3d.c` |
| `ZSLICE_ZOOM_AT=x,y,n` | Zooms `n` wheel steps toward the pixel x, y after the first load. | `ui/view3d.c` |
| `ZSLICE_INSPECT_FOCUS=name` | Puts the focus on the row of the setting `name` in the inspector after the first selection. | `ui/inspector.c` |
| `ZSLICE_SETTING=name` | Opens the Settings page at the setting `name`. | `ui/settings-browser.c` |

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
2. Wrap `zs_app` in one object of the platform (a GObject, an ObservableObject, a ViewModel) that owns the core and moves the events to the UI thread. See `linux/src/model/app-model.c`.
3. Build the window: open, export, the settings panel, the preview with a layer slider, a status bar, and a Licenses screen.
4. Use the GTK shell as the reference for the behavior.

The structure follows the Lookout Marine app (a Zig core with native shells for each platform, by the same author).
