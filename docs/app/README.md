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

## The preview colors

All shells use the same colors, in the order of `enum zs_feature`:

| Feature | Color |
|---|---|
| Outer wall | `#d9480f` |
| Inner wall | `#f59f00` |
| Skin | `#1c7ed6` |
| Infill | `#2b8a3e` |
| Ironing | `#ae3ec9` |

## Add a shell

1. Build the core for the platform: `zig build lib -Dtarget=<target> -Doptimize=ReleaseFast`. It makes `libzslice.a` and the two headers.
2. Wrap `zs_app` in one object of the platform (a GObject, an ObservableObject, a ViewModel) that owns the core and moves the events to the UI thread. See `linux/src/model/app-model.c`.
3. Build the window: open, export, the settings panel, the preview with a layer slider, a status bar, and a Licenses screen.
4. Use the GTK shell as the reference for the behavior.

The structure follows the Lookout Marine app (a Zig core with native shells for each platform, by the same author).
