# 12. The Windows app (WinUI 3 and Direct3D 12)

## Goal

Build the native Windows app in `windows/`: a WinUI 3 shell in C++/WinRT around the app core, with a Direct3D 12 backend in the core. It builds for x64 and ARM64. The port is in progress at the commit this folder describes, and it has most features of the other apps. It starts no print yet. Build the parts in the order below, and match the web app for each part.

## Read first

- [The Windows app internals](../docs/internals/windows.md): the build, the shell files, the printers, the core build, the Direct3D 12 backend, and the differences from the other platforms. The file table lists the session, the menu, the printers, the picker, the farm, the send, the search, the work bar, the links, Preferences, and Compare with Cura.
- [Links that open a model](../docs/internals/open-links.md). `windows/src/net/zs_open_link.cpp` calls the core rules (`zs_link_*`).
- [The Windows app user guide](../docs/user/windows.md).
- Part 08 (the view) and part 09 (the layout, the cards, and the keys).

## Build

1. `windows/build-core.ps1 -Platform x64` (and `ARM64`): `zig build lib` for the MSVC target, ReleaseFast, with `-Dcompiler-rt`. The results stay apart under `zig-out/windows-x64` and `zig-out/windows-arm64`. An ARM64 core on an x64 machine gets a libc file with the ARM64 library folders.
2. `windows/build-tests.ps1`: `core_link.c` (a UTF-8 path outside the ANSI code page), `view_offscreen.c` (draws with Direct3D 12 and checks the pixels; `ZSLICE_WARP=1` for the software rasterizer), and `net_link.cpp` (links against stub servers on 127.0.0.1).
3. `msbuild ZSlice.vcxproj -t:Restore`, then `msbuild ZSlice.vcxproj`, as two calls. The app is unpackaged and self-contained.
4. `src/render/d3d12.zig` with the interface of `vk.zig`, and HLSL forms of each GLSL shader in `src/render/shaders/d3d12`. A change to a GLSL shader needs the same change there. Declare the COM vtables in `src/render/c_d3d12.zig`, so the build needs no Windows SDK header.
5. A composition swapchain on `ZS_SURFACE_PANEL` for a `SwapChainPanel` (`zs_view_swapchain`). Frame latency 1 and a waitable object. A frame that the compositor cannot take returns `ZS_BUSY`; draw again 8 ms later.
6. The shell files in the table of the internals page: the model (no WinRT), the plate bar and signs (GDI+), the settings pane, the tools, the cards, the filaments, Paint, Label, Support, the session, the menu, the context menu, the 2D view (Direct2D on its own swapchain), the chrome, the color tokens of `web/app/style.css`, the printers, the picker, the farm, and the send.
7. `src/prefs/`: secrets with DPAPI (`CryptProtectData`). `app.ini` has no secret. It has the theme, the first view, and the slicer threads.
   - Preferences (the main menu and Ctrl+,): the Printers and General pages of the GTK app. No USB rows, and no settings for each roll.
   - File types and links (`src/prefs/zs_app_shell`): Open With for STL, 3MF, STEP, and OBJ, and `zslice://open?file=<URL>`, in HKCU for this user. The app takes the default of no file type. A later start gives its file or link to the open window through a named pipe.
8. `src/net/`: WinHTTP, Schannel, the printer links, the search, Bambu Lab, and the cameras.
9. The rest of the window, in the order it came: the docked search with its card and rails, the print details card, the history card and list, the draft slice with the work bar, one Check count, Compare with Cura, and printdeck projects.
   - Compare with Cura: `zs_cura_stack` finds the stack in `%APPDATA%\cura` and the resources in the Cura folder of Program Files. Of a global stack file, it parses only `[containers]`, because `[metadata]` can hold an API key.
   - The parity steps after that, in the order they came: the small items (the monochrome glyph of the colors button, long titles that wrap, search results 640 px wide with a column for the speed hint, two save items for one plate and all plates), the card glyph of the search undock, the Label tool with SVG, handles, guides, and modes (Alt turns the snap off), profile import and Calibrate, the layer range card (Shift+K and Shift+J, an override of the z range), Print earlier and Print later, the settings of each nozzle, the history button (Ctrl+H) in a bottom bar of one row, the waste line, the Filament row and the range rows of a part of some layers (the rows of the range card scroll), the Speed section with the switches of the draft slices and the print as it forms in Preferences, layer profiles in the settings pane (a bar with the name and the layers, and an orange mark on the layer rail for each range), a part that does not fit (no export and no upload for its plate, and a Check line that selects the part), and "Settings for": this print, global (`global.toml`), or one part. Formulas stay after a restart.
   - The icon: the exe holds the `.ico` file of 16 to 256 px, and the file types and links use it. `make-logos.ps1` draws the package logos, but the unpackaged app does not load them yet.
   - Windows keeps Move, Turn, and Grab as three tools. It does not have the transform tool yet.
   - Projects: GitHub reads use a separate WinHTTP session with no key or token. Each URL and each redirect must be https to a GitHub host. Each file has a limit of 256 MB. PrinterSetup writes no machine profile while plates of a project are on the view.
   - The part card: the settings that the part has of its own (`zs_app_part_setting_set`), each with its editor and ×, and "+ Add a setting" for the selected part or parts. The filament stays in its row of chips.
   - The line card: "Support you added" for a line at a support mark, with its kind, its radius, and Remove (`zs_app_mark_at`, `zs_app_mark_set`, `zs_app_mark_remove`).
   - The import of a model (`MainWindow.ModelImport.cpp`, [the contract](../docs/internals/model-import.md)): a page link gets the text of the core and **Open the page**. A ZIP file from Open, a drop, or Open With gets the list, with Cancel as the default button. The checked files become parts, then `zs_set_spill`. No request goes to a site.
   - The spools of a printer: `zs_app_filaments_from_printer`, with flag 1 for **Use the filaments of** and flag 2 for each status of the current printer.
   - The link to the current printer, also with the Printers page closed: one status read each 5 s for an HTTP printer, and one MQTT connection for a Bambu Lab printer. A printer never has two connections.
   - The rest of the core API: the User-Agent of the core on file links (`zs_import_user_agent`), Popular and the counts in the printer picker, `zs_app_fall_cancel` before each change of the plate, the key of a line for edits during a slice (`zs_app_path_key`, `zs_app_edit_add_key`), Shift+click for a run (`zs_app_path_run`, `zs_view_highlight_more`), the float note and the file settings on the part card, the test print in the view menu (`zs_app_debug_gcode`, a saved file only), the lines of a setting with their times (`zs_app_feature_stats`), and the empty-plate button that hides under another plate (`zs_view_plate_at`).
   - The clipboard has one kind at a time: parts (in the core), a label (its JSON), or the changes of some layers. A copy takes the selected label, then the layers of the open range card, then the parts. Support areas and setting values do not copy yet.
   - A double click on a history change goes to its step and opens the change on its part, in its layers, or for the print. A change outside some layers leaves an open profile, so a new edit cannot go to those layers.
   - Windows calls `zs_set_project_load` for a project, so it needs no separate `zs_project_profiles` or `zs_app_project_load`. It has no islands button: the Check lists the islands.

## Rules that matter

- Each path in the C API is UTF-8. `zs_gcode_open` converts to UTF-16 and calls `_wfopen`.
- The session is `session.zslice` in `%APPDATA%\zslice`. Write no session until the restore at launch is done. A session that does not read moves to `session.zslice.bad`.
- Mouse: a left drag orbits. A right drag orbits with a mouse, and pans with a two-finger click on a touchpad. The middle button and Shift pan. The wheel and a pinch zoom.
- A Label edit goes to the core 400 ms after the last change or at the end of a drag, so it is one history step. A Support drag sends its edit at most each 60 ms and slices at most each 150 ms.
- **No print starts from the Windows app yet.** `zs::link::Upload` always sends `print=false`. The Bambu Lab link sends no PUBLISH.
- A request follows no redirect and uses no proxy, so a key cannot go to another host.
- A link resolves the host before each request, and refuses a local address. A status callback closes a connection to a local address before the TLS handshake.
- A failed slice shows `zs_status_message` and turns off Export. The log gets `zs_app_failure_name`, for a bug report.
- A loaded file is its own history step. Else the first edit after a load joins that step, and the refinements have no guide.
- The view builds its matrices for a clip space with y down; the vertex shaders negate y. `SV_InstanceID` starts at 0 for each draw, so a root constant gives the first instance for the highlight.
- The backend writes its log lines to stderr itself: `std.log` does not compile for ARM64 Windows in Zig 0.16.
- After a refused or dropped MQTT connection, wait at least 15 s, then twice as long each time, to 5 minutes. A printer in LAN mode takes few clients. A wrong access code (return code 4 or 5) stops the watch until the details change. After 5 minutes minimized, close the links.

## Lessons

- Keep the x64 and ARM64 cores side by side, so both platforms stay built.
- A command-line build does not register the generated XAML files: compile them in `winrt_glue.cpp`.
- **Keep the hand-off pipe open until the client reads.** The first window disconnected the pipe right after its answer, and a disconnect drops unread data. Under load, the second start saw no answer and opened a second window. Keep the pipe until the client closes it, for at most 2 seconds.
- **Keep the session in the state folder.** A missing backslash put the session in `%APPDATA%zslice`. At the first start, move the old files into `%APPDATA%\zslice`. Keep a file that is already there.
- **Send the log lines to the log file.** A WinUI app has no console, so `fprintf` to stderr lost the setup lines.
- **Save the settings again after a load that moved keys**, as the other apps do (part 02).
- **Forget a draft when its plate goes.** The model kept a pointer to the plate with a draft. A removed plate left that pointer dangling until the timer of the exact slice read it.
- **Fold the bottom bar by its own width.** The bar measured the whole window. With the settings pane open it kept one row, and the pane cut off the Export button.
- **Write no empty file.** An export wrote an empty file when the plate had no G-code.
- **An empty deck path means the root of the deck** (part 13). The pairing had this right, and `DeckAddress` follows it now too.
- **Find a support mark from the whole line.** A slice can renumber the lines and drop the selected segment. The middle of a long wall is then far from the mark, and the card lost its editor right after the mark was added.
- **Keep a key out of each log, also in a test build.** The step log of the test hooks wrote the text of `prefset key` to the log file. The log now hides that step.
- **Fill the times of a setting's lines after the slice.** A change refilled the page during the slice, when the core has no stats, and the times stayed away. `AfterScene` now fills them again.
- **Say where a default value comes from.** The page wrote "From:" with no source for a default. It now has the wording of the GTK app, and Reset shows only for a change.

## Acceptance checks

1. CI builds the core and links the tests for x64 and ARM64, and builds the app with msbuild.
2. `view_offscreen.c` draws a model, and its pixels pass, also after a resize.
3. `net_link.cpp` passes against the stubs, and contacts no real printer.
4. The app opens a model, slices it, draws it, and shows the plates with signs and bed models.
5. A close and a start bring back the session.
6. A second start with a file opens it in the first window, with no second window.
7. A test of the link code shows that a local stub gets no byte.
8. The ring drag hook of the test build drags a ring along a right-hand turn, and logs the angle from the front, the back, or above.
9. A part with its own wall count keeps it through undo and redo, and × gives it the value of the plate again.
10. A line at a support mark shows the kind and the radius of the mark. A change of either reaches the core, and Remove takes the mark away.
11. A ZIP file with more parts than one bed holds loads its checked files, and the parts that do not fit go on new plates. A file that is not a ZIP file shows the message of the core.
12. Against a stub printdeck, **Use the filaments of** sends one GET and makes the plate its spools. The follow changes a printer with `machine.filament_change = tool`, and no other. No log has the key.
13. With the Printers page closed, a stub printer gets one status read each 5 s, and none after the printer has no link. A broker that answers "server unavailable" gets its next CONNECT no sooner than 15 s later.
