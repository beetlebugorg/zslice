# The Windows app

The Windows app is a native shell over the Zig core, in `windows/`: a WinUI 3 shell in C++/WinRT, and a Direct3D 12 backend in the core. Only the core is shared with the other apps.

The port has most features of the other apps: the plates and bed models, the settings with the docked search and its rails, history, the tools and their cards, the filaments, the printers with send and export, the print details, Compare with Cura, Preferences, printdeck projects, file types and zslice:// links, the session restore, and the draft slice with the work bar. The parity list in docs/app/README.md names what is still open. This page describes the parts that exist.

## Build the app

The app is unpackaged and self-contained: the build copies the Windows App SDK next to the program. Build the core first, then the shell, for each platform:

```powershell
pwsh windows/build-core.ps1 -Platform x64
cd windows
msbuild ZSlice.vcxproj -t:Restore -p:Configuration=Release -p:Platform=x64
msbuild ZSlice.vcxproj -p:Configuration=Release -p:Platform=x64
.\x64\Release\ZSlice.exe part.stl
```

Use `-Platform ARM64` and `-p:Platform=ARM64` for ARM64. The project takes the default toolset of the Visual Studio that builds it (v143 for 2022, v145 for 2026). Run the restore and the build as two calls: the first import of the project exists only after the restore. `ZSLICE_LOG=path` writes the log lines of the shell and the core to a file.

### Test hooks

A build with `-p:ZsDevHooks=true` reads `ZSLICE_DO`: steps with `;` between them, one each 600 ms after the first slice, on the same code that the pointer and the keys call. A test then needs no real input. Each step writes the state of the tools to the log. The steps are `tool V`, `click x y [shift] [ctrl]`, `drag x0 y0 x1 y1 [ctrl]`, `turnz degrees`, `hover x y`, `key NAME`, `layer n`, `colors n`, `sim`, `gaps 0|1`, `play`, `scrub f`, `check`, `bed`, `probe x y`, `undo`, `redo`, `orbit dx dy`, `zoom f`, `look nx ny nz d`, `press NAME`, `newplate`, `plate n`, `shot NAME`, `wait`, and `log`. `part` in place of `x y` is the middle of part 0 on the screen. `press` invokes a button by its automation name or text through its automation peer, with `_` for a space. `shot` only writes a line, so a script outside can take a picture. The header of `MainWindow.DevHooks.cpp` lists the steps of the Paint tool (`p...`), the Label tool (`l...`), the filament list (`f...`), and the range of layers (`range...`). The Support tool adds its own steps, listed there too. `ZSLICE_PRINTER=id` starts on a printer of the library. A shipped build has none of the `ZSLICE_DO` code.

## The shell

| File | What it has |
|---|---|
| `src/model/zs_model` | The core as one object: the plate set, the file reads, and the core events. It has no WinRT. |
| `src/model/zs_signs` | Draws the text of the plate signs into one image with GDI+. |
| `src/model/zs_part_meshes` | The meshes of the parts, each with a paint session. Paint and Label share them. It has no WinRT. |
| `src/model/zs_label` | A label: its JSON, its frame, and its shapes. It uses `Windows.Data.Json`. |
| `src/app/MainWindow.xaml.cpp` | The window: the view in a `SwapChainPanel`, the open flow, and the events of the core. |
| `src/app/MainWindow.Plates.cpp` | The plate bar, the signs, and the switch of the active plate. |
| `src/app/MainWindow.Settings.cpp` | The settings pane from the descriptions of the core, the search, and the history. |
| `src/app/MainWindow.Tools.cpp` | The tool strip, the pointer, the keys, the selection, Move, Turn, Grab, and Measure. |
| `src/app/MainWindow.Cards.cpp` | The line card and the part card, placed beside what they describe. |
| `src/app/MainWindow.Range.cpp` | The card of a range of layers: the drag of the Select tool, Shift+K and Shift+J, the light, the overrides, and the search of these layers. |
| `src/app/MainWindow.View.cpp` | The line colors, the print as it forms, the replay, the gaps, the check, and the bed. |
| `src/app/MainWindow.Filaments.cpp` | The filament button and its list, the round chips, and the filament, label, and paint rows of the part card. |
| `src/app/MainWindow.Paint.cpp` | The Paint tool and its card. |
| `src/app/MainWindow.Label.cpp` | The Label tool, its card, the handles on the surface, the smart guides, and SVG pictures. |
| `src/app/MainWindow.Support.cpp` | The Support tool: the areas, the trees, its card, and the pick of a support line by the Select tool. |
| `src/app/MainWindow.Session.cpp` | The session: written after a slice and at the close, and put back at the start. |
| `src/app/MainWindow.Menu.cpp` | The main menu, the sheet of the keys, Licenses, About, and the theme. |
| `src/app/MainWindow.ContextMenu.cpp` | The menu of the view, and copy, cut, paste, and duplicate of parts. |
| `src/app/Layer2D.cpp` | The 2D view of one layer, with Direct2D on its own swapchain. |
| `src/app/MainWindow.Layer2D.cpp` | The input and the state of the 2D view. |
| `src/app/MainWindow.Chrome.cpp` | The layer rail, the timeline, and the print in the bottom bar. |
| `src/app/MainWindow.Search.cpp` | The search of settings and actions: docked, on a card, or on a rail. It has no action that starts a print. |
| `src/app/MainWindow.Summary.cpp` | The details of the print: the facts, the warning, and the refinements (`refine.txt` in the state folder). |
| `src/app/MainWindow.History.cpp` | The history button and its count, the list of the steps, the undo of one change, the line edits, and the layout of the bottom bar. |
| `src/app/MainWindow.Work.cpp` | The timer of the exact slice after a draft, the work bar of 2 px, and its text. |
| `src/app/MainWindow.Open.cpp` | A file or a `zslice://` link from outside the app. A link asks before it downloads. |
| `src/net/zs_open_link` | The download of a link, with the rules of the core (`zs_link_check`, see [Links that open a model](open-links.md)). It resolves the host first, and it closes a connection to a local address before the TLS handshake. |
| `src/app/MainWindow.Project.cpp` | The printdeck.yml project: its dialog, its plan, the status of its plates, and `project.json` in the state folder. |
| `src/app/MainWindow.Import.cpp` | "Import a profile…" (`zs_app_profile_import`), its report, and the dialog that the report and the calibration share. |
| `src/app/MainWindow.Calibrate.cpp` | The Calibrate menu and its search actions, the test on a new plate (`zs_app_calibration_add`), and the buttons that use a value. A test never sends a file. |
| `src/net/zs_project_source` | The files of a project: a public GitHub repository at one commit, or a folder. |
| `src/prefs/zs_app_shell` | The file types and the link scheme in HKCU, and the hand-off to the first window through a named pipe. |
| `src/app/App.xaml` | The color tokens of `web/app/style.css` for light and dark, and the flat button styles. |
| `src/app/MainWindow.DevHooks.cpp` | The test hooks, in a build with `ZsDevHooks`. |
| `src/app/App` | The start of the app, and `ZSLICE_LOG`. |
| `src/app/winrt_glue.cpp` | Compiles the generated XAML files, which a command-line build does not register. |
| `src/app/MainWindow.Printers` | The setup group of the top bar, the panels over the window, and the pairing. |
| `src/app/MainWindow.Picker.cpp` | The printer picker. |
| `src/app/MainWindow.Farm.cpp` | The Printers page and the list of the printers of the user. |
| `src/app/MainWindow.Preferences.cpp` | Preferences: the printer list and form, the theme, the first view, and the slicer threads. |
| `src/app/MainWindow.Send.cpp` | Send, export, the plate as 3MF, the project, and all plates. |
| `src/app/MainWindow.CuraCompare.cpp` | The "Compare with Cura" window, as in `linux/src/ui/cura-compare.c`. It is a second XAML window, owned by the main window, so the settings and Undo stay in reach. Any call of `RefreshSettingValues` refreshes it. |
| `src/prefs/zs_cura_stack` | Finds the stack of the active Cura printer in `%APPDATA%\cura`, and reads its files for `zs_app_cura_compare`. |
| `src/prefs/` | The state folder, the saved printers, the secrets, and the setup of a plate. It has no WinRT. |
| `src/net/` | HTTP (WinHTTP), TLS (Schannel), the printer links, the search, Bambu Lab, and the cameras. It has no WinRT. |

- The core events come on the slice threads. The model posts each one to the UI thread through the `DispatcherQueue`.
- The view draws only after a change. `ZS_BUSY` means that the compositor holds the frame before, and a timer draws again 8 ms later.
- The swapchain is in device pixels. The shell sets the inverse of the composition scale on it with `SetMatrixTransform`.
- The session is `session.zslice` in `%APPDATA%\zslice`, or in `ZSLICE_STATE_DIR`. The app writes no session until the restore at launch is done. A session that does not read moves to `session.zslice.bad`.
- A left drag orbits, except a drag of the Select tool that starts on a printed line: that drag selects layers. A right drag orbits with a mouse and pans with a two-finger click on a touchpad. The middle button and Shift pan. The wheel and a pinch zoom.
- The Paint tool gives the view the mesh of the part (`zs_view_paint_mesh`), and the view draws it in place of the beads. A stroke changes the paint session at once. Its end gives the paint to the part: one step of the history, and a slice. A reload after a slice or an undo compares the text of the paint, so the session follows an undo.
- The Label tool keeps a copy of the labels of one part. An edit shows at once, and goes to the core 400 ms after the last change or at the end of a drag, so it is one step of the history.
- The handles of a label are decals of the core view (`zs_view_label_add`) in the plane of the label, with sizes in points of the screen. A zoom of more than 8 % draws them again. A move or a resize calls `zs_label_snap` at each step, with the face of `zs_label_face`. A drag shares the JSON items of the label, so an SVG source is not written to text at each step.
- "Place an SVG…" uses `IFileOpenDialog`, for the title and the filter name of the GTK dialog. A drop of an `.svg` file goes to the Label tool when the 3D view is the top element at the point of the drop.
- The state of Paint, Label, and the filaments is in structs inside their `.cpp` files. `MainWindow.xaml.h` has only a pointer to each and the calls that other files need. Their cards are built in code, so `MainWindow.xaml` has only the filament button.
- The Support tool keeps a copy of the areas and the trees. It reads them again after a load of the view, an undo, and a switch of the plate. During a drag the copy leads, and the slices wait for the release. A drag of a tree sends its edit at most each 60 ms, and slices at most each 150 ms.
- The range card edits overrides (`zs_app_override_set`) of the z range from the top of its first layer to the top of its last. An `EditorTarget` gives `MakeEditor` the values of the range in place of the values of the print. A search with a `SearchScope` lists only the settings that pass `only`, and its rows use the target of the scope. A running slice has no toolpaths, so the card keeps the heights of the last slice. `zs_view_load` clears a lit body, so `RangeScene` lights it again after each scene.
- The list of the parts of a plate is its print order with `project.print_sequence = by_object`. **Print earlier** and **Print later** call `zs_app_part_reorder`, and the selection follows the part.
- `ShowSpeedSection` builds the Speed section from `zs_speed_get`. The switch has no value of its own: `zs_app_speed_state` reads it from the options. `engine.threads`, `engine.draft_slices`, and `engine.auto_simulate` are app preferences. `ApplyEnginePrefs` gives them to each plate, and `KeepEnginePref` saves a change made in the pane.
- The section list shows "Second nozzle" only with `machine.nozzles` at 2. `RefreshSettingValues` builds the list again when that changes. The line card reads the nozzle of the line from `zs_inspect.nozzle` and `nozzle_text`.
- A change of a plate with a slice gives a draft (`zs_app_set_draft`). `Model::LiveChange` starts a timer of 300 ms, and `Model::Settle` starts the exact slice at its end or at the end of a drag. A draft has no G-code, so the file, the session, the refinements, and a batch wait for the exact slice.
- One window has each state folder, so that two windows do not overwrite one session. A later start gives its argument to the first window and exits. The first window restores its session before it opens a file.
- A shipped build writes the file type keys when they differ from its path. A build with test hooks, or a run with `ZSLICE_STATE_DIR`, writes none.

## Projects

- **Network.** `zs_project_source` has its own WinHTTP session, with no key, token, cookie, login, or proxy. Each URL and redirect must be https on port 443 of `github.com`, `api.github.com`, `raw.githubusercontent.com`, or `media.githubusercontent.com` (Git LFS), and the peer must be a public address.
- **Limits.** A file has at most 256 MB, one load 1 GB, an API answer 64 MB, `printdeck.yml` 4 MB, and a list 200000 files.
- **Paths.** A read accepts only a path of the list of the source: the blobs of the tree, or the files of a walk of the folder. The walk skips `.git`, links, and junctions.
- **Plates.** An open loads all plates with `zs_set_project_load`. The dialog matches a plate of the set to a plate of the plan by `zs_plate_info.id`, so a removed or added plate needs no call.
- **The printer of the user.** While plates of a project are on the view, `PrinterSetup::SaveState` writes no machine profile and no filament of the printer. A model file that replaces the plates ends this mode. A pick of a printer ends it on a set of one plate. With more plates, the active plate gets the machine of the printer and the mode stays, because another plate can still have the machine of the project. The session keeps the mode, so a restart does not write the machine of a project to the printer.
- **Session.** The session has a tag of the project and the map of its plates. A session with another tag leaves the plates to the user, and the dialog offers **Open** again.

Test hooks of the project are `pjshow`, `pjhide`, `pjfolder`, `pjgithub`, `pjplate`, `pjstatus`, `pjcount`, `pjcheck`, `pjclose`, `pjscroll`, `pjfile`, `pjmenu`, `pjactions`, `pjsum`, and `pjlog`.

## Import and calibration

- **Import.** The file reads on a worker thread. The core changes the settings of the active plate. The shell commits an edit that is still open, then commits the import as its own step of the history.
- **Calibration.** A test adds a plate, which copies the settings of the active plate, and puts the test on it. If the core returns an error, `Model::Settle` runs before the new plate goes, as in the GTK shell. The plate before the test gets its exact slice from `Model::RequestSlice`.
- **Use a value.** The value goes on each plate through `zs_app_setting_set`. The other plates slice again. The history commits on the active plate, as in the GTK shell.
- **The dialog.** `PrintersUi::ShowInfoPanel` opens one dialog at a time, with the token `ZsDialog` (`--dialog` of the web app). The keys stay in the dialog, so a key of a tool does not change the plate behind it.

Test hooks are `importmenu`, `importrun`, `importfile`, `importlog`, `calmenu`, `calopen`, `calsub`, `calrun`, `calfind`, `calshow`, `caluse`, `calclose`, `callog`, `popupshot`, and `qualityshot`. In a hooks build, `ZSLICE_IMPORT_FILE=path` replaces the file dialog.

## Printers

- **No print starts.** `zs::link::Upload` always sends `print=false`, and it has no parameter for it. The Bambu Lab link sends no PUBLISH.
- **Secrets.** `src/prefs/zs_state` encrypts API keys, access codes, and the signing key with DPAPI (`CryptProtectData`) for the Windows user. `app.ini` has no secret.
- **Redirects and proxies.** A request follows no redirect and uses no proxy, so a key cannot go to another host. A camera at another origin gets no key.
- **Certificates.** An https printer is pinned as in the GTK shell. A Bambu Lab printer is pinned at the first connection: on another certificate, the TLS client closes before it sends the access code.
- **Threads.** Network calls block on worker threads. A worker posts its result to the UI thread through `PrintersUi::Poster`.

These variables change a run, for tests:

| Variable | Effect |
|---|---|
| `ZSLICE_STATE_DIR=dir` | Keeps the state in `dir`, not in `%APPDATA%\zslice`. The printer search then stays off the network. |
| `ZSLICE_DISCOVERY` | `off`, `network`, or `127.0.0.1:<port>` (a stub on the loopback address). |
| `ZSLICE_SAVE_DIR=dir` | Skips the save dialogs, and writes the files to `dir`. |
| `ZSLICE_PLATES=file;file` | Adds a plate for each file, one each 1.5 s, then goes back to plate 1. |
| `ZSLICE_BAMBU_MQTT_PORT`, `ZSLICE_BAMBU_JPEG_PORT` | Move the ports of a Bambu Lab printer, for a stub. |
| `ZSLICE_PRINTER=id` | Starts on a printer of the library, with no picker. |
| `ZSLICE_CURA_RESOURCES=dir` | The resources of Cura for "Compare with Cura", in place of the Cura folder in Program Files. |

`windows/test/net_link.cpp` tests the links against stub servers on 127.0.0.1: HTTP, canned mDNS and SSDP packets, and a TLS server with a self-signed certificate. It contacts no real printer.

At the start, the app reads `/slicer/printer.json` of each deck with saved printers. Each printer with a deck name gets the address of the printer of that name. The first printer of a deck has an empty path and lives at the root of the deck, so `/printers/<id>` of the first printer does not exist. A deck that does not answer keeps its addresses.

## Preferences

- `app.ini` keeps `theme`, `view`, and `engine.threads` in `[general]`, through `zs::Printers().Pref` and `SetPref`.
- The theme is `RequestedTheme` of the root element. `ThemeDialog` gives it to a dialog, with the background token. With a chosen theme, `ui::ThemeBrush` returns the color token of that theme. A change of the theme builds the Printers page again.
- A profile has no engine settings, and a new plate does not copy them. `ApplyThreadsPref` gives the thread count to each plate. A plate that waits for a slice or slices gets it at its next status event.
- `zs_app_setting_set` records no pending history edit for `engine.threads`, because a history step has no engine options.
- The panel has no USB rows and no "Keep filament settings for each roll" row. The Windows shell has neither feature.

## The icon

The exe and the window use `assets/icon/out/zslice.ico` through `windows/ZSlice.rc`. The file types and links use the first icon of the exe. `windows/make-logos.ps1` draws the package logos in `windows/Assets` from `assets/icon`, with the SVG renderer of Direct2D. Art below 48 px comes from `zslice-small.svg`. The app is unpackaged, so it does not load the logos yet. An MSIX package uses them. Run the script after a change of the icon, and commit its files.

## Build the core

The core needs Zig 0.16 and Visual Studio with the C++ tools. The app builds for x64 and ARM64.

```powershell
pwsh windows/build-core.ps1 -Platform x64
pwsh windows/build-tests.ps1 -Platform x64
pwsh windows/build-core.ps1 -Platform ARM64
pwsh windows/build-tests.ps1 -Platform ARM64
```

- **`build-core.ps1`** runs `zig build lib` for the MSVC target of the platform. The result is `lib/zslice.lib` and `include/` under `zig-out/windows-x64` or `zig-out/windows-arm64`, so both platforms stay built.
  - A Release core is ReleaseFast.
  - The script sets `-Dcompiler-rt`, so the library has the f128 helpers that `std.json` and `std.fmt.parseFloat` call.
  - For an ARM64 core on an x64 machine, the script gives Zig a libc file with the ARM64 library folders.
- **`build-tests.ps1`** compiles the programs in `windows/test` with MSVC, links the core, and runs them.
  - `core_link.c` opens a G-code file by a UTF-8 path with characters outside the ANSI code page.
  - `view_offscreen.c` draws a model with Direct3D 12, reads the frame, and checks its pixels, also after a resize. Set `ZSLICE_WARP=1` to run it on the software rasterizer.
  - `net_link.cpp` tests the printer connections, the saved printers, the setup of a plate, and the rules of a project source.

To link an ARM64 program, Visual Studio needs the component "MSVC ARM64 build tools" (`Microsoft.VisualStudio.Component.VC.Tools.ARM64`). The core itself compiles without it. An x64 machine builds the ARM64 test programs and does not run them.

## The Direct3D 12 backend

`src/render/d3d12.zig` has the interface of `src/render/vk.zig`, so `src/render/view.zig` is the same on each platform. The HLSL files in `src/render/shaders/d3d12` are the forms of the GLSL shaders. A change to a GLSL shader needs the same change there.

- A view on `ZS_SURFACE_PANEL` makes a composition swapchain. The shell gets it with `zs_view_swapchain` and gives it to `ISwapChainPanelNative::SetSwapChain`.
- The swapchain has a frame latency of 1 and a waitable object. A frame that the compositor cannot take returns `ZS_BUSY`, so a present does not block the UI thread.
- The view builds its matrices for a clip space with y down. The vertex shaders negate y.
- `SV_InstanceID` starts at 0 for each draw. A root constant gives the shader the first instance of the draw, for the highlight.
- The backend writes its log lines to stderr itself. `std.log` does not compile for ARM64 Windows in Zig 0.16.
- A print view offscreen draws all its layers each frame. It has no cached image of the finished layers.

## What differs from the other platforms

- `zig build lib` installs only the static library on Windows. The import library of a DLL has the same name, `zslice.lib`.
- Each path in the C API is UTF-8. `zs_gcode_open` converts the path to UTF-16 and calls `_wfopen`.
- `zslice bench` reads the CPU time with `GetProcessTimes`, and the page faults and the peak memory with `K32GetProcessMemoryInfo`.
