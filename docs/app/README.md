# The zslice app

The zslice app has one core and one native shell for each platform:

| Platform | Shell | Folder | Status |
|---|---|---|---|
| Linux | GTK4, C | `linux/` | Works |
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

The backend is Vulkan on Linux (and later Windows and Android), and Metal on Apple later. The core loads the Vulkan loader at run time, so a shell does not link it. Without Vulkan, `zs_view_new` returns `ZS_NOT_SUPPORTED`, and the shell shows the 2D view only.

On Linux, the GTK window is transparent, and the view widget draws nothing: the subsurface shows through it. Each other part of the window must paint its whole area (use padding, not margins).

Development options of the GTK shell: `ZSLICE_VIEW=3d` opens the 3D view, and `ZSLICE_NON_UNIQUE=1` starts a separate instance.

## Inspect a path

A click on a path in a view picks it: `zs_app_pick_layer` in a 2D layer view (a point in mm), and `zs_view_pick` in the 3D view (a pixel). `zs_app_inspect` then gives what the path is, its real values (the bead width, the planned and the real speed, the flow, the time span), the reasons for them in plain words, and the names of the settings that change it. The shell shows the text and an editor for each setting, and highlights the path (`zs_view_highlight`).

After a new slice, the path numbers change. The GTK shell keeps the layer and a point of the selected path, and picks the path at that place again, so that the inspector stays on the same line after a setting changes.

Development option of the GTK shell: `ZSLICE_PICK=x,y` picks at a pixel of the 3D view after the first load.

## Replay

`zs_view_set_time(view, t)` shows the print as it is t seconds after the start: each bead that is done, and the part of the bead that the nozzle is printing. The times come from the G-code emitter, with the cooling slow-down, so the replay follows the G-code. A shell moves t on each frame while it plays (GTK: a frame-clock tick callback, at a speed of 1x to 100x), and shows `zs_view_layer_at_time` on its layer slider. `zs_view_set_layer` ends the replay.

Development option of the GTK shell: `ZSLICE_TIME=t` shows the replay at t seconds before the first frame.

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

## Add a shell

1. Build the core for the platform: `zig build lib -Dtarget=<target> -Doptimize=ReleaseFast`. It makes `libzslice.a` and the two headers.
2. Wrap `zs_app` in one object of the platform (a GObject, an ObservableObject, a ViewModel) that owns the core and moves the events to the UI thread. See `linux/src/model/app-model.c`.
3. Build the window: open, export, the settings panel, the preview with a layer slider, a status bar, and a Licenses screen.
4. Use the GTK shell as the reference for the behavior.

The structure follows the Lookout Marine app (a Zig core with native shells for each platform, by the same author).
