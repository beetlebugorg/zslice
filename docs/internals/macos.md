# The macOS app

The macOS app is a native shell over the Zig core. It is in `macos/`. It uses SwiftUI, AppKit where SwiftUI falls short, and Metal for the 3D view. Only the core is shared with the other apps. The app follows the layout plan in [One view](one-view.md), in the way a Mac app does it.

## Build

The app needs Zig 0.16 and the Swift 6 tools of Xcode (macOS 14 or later).

```sh
cd macos
ZIG=/path/to/zig-0.16/zig ./build-core.sh   # lib/libzslice.a, for arm64 and x86_64
./make-app.sh                                # build/zslice.app
open build/zslice.app
```

`build-core.sh` runs `zig build lib` for `aarch64-macos` and `x86_64-macos`, and merges the two static libraries with `lipo`. The archive of Zig 0.16 does not align its object to 8 bytes, and the Apple tools (`ld`, `lipo`, `libtool`) then skip the object with no error. So the script takes the object out of each archive and makes the archive again with `libtool` before `lipo`. It also sets `-Dcompiler-rt`, which puts the compiler-rt of Zig in the library: the Apple linker has no libgcc for the f128 helpers that `std.json` and `std.fmt.parseFloat` call. `make-app.sh` builds the Swift package (`swift build`), and makes the app bundle with `Info.plist` and an ad-hoc signature. The project is a Swift package, not an Xcode project, so the build files are plain text.

## The parts

| File | What it does |
|---|---|
| `Package.swift` | The package: the C module and the app target. |
| `Sources/CZslice/module.modulemap` | The C API of the core (`include/zslice-app.h`) as the Swift module `CZslice`. |
| `Sources/ZSlice/ZSliceApp.swift` | The app and its document type. Each window is one STL or 3MF file. |
| `Sources/ZSlice/Core/SliceModel.swift` | The plates of a window (one `zs_set` of the core), the active plate, its state, and the events. |
| `Sources/ZSlice/Core/Workspace.swift` | The model of a window: the plate, the 3D view, the layer range, the replay, the focus of the drawer, and the keys of the view. |
| `Sources/ZSlice/Core/History.swift` | The undo list of the core on the `UndoManager` of macOS: the commit timer, the focus of an edit, and the timeline. |
| `Sources/ZSlice/Core/Selection.swift` | The selected line: the pick, the highlight, the facts of the line card, the line again after a new slice, and the keys of a selected line. |
| `Sources/ZSlice/Core/Tools.swift` | The tools of the view: Select, Move, Turn, and Measure. |
| `Sources/ZSlice/Core/Throttle.swift` | Runs an action at most once in an interval during a drag, and once more at the end. |
| `Sources/ZSlice/Core/Printers.swift` | The library of printer models, the bed models, and the printers of the user (API keys in the Keychain). |
| `Sources/ZSlice/Core/PrinterLink.swift` | Print, upload, test, and Get a Key over HTTP, https first. |
| `Sources/ZSlice/Core/Discovery.swift` | The printers on the network: the UDP of the mDNS search of the core. |
| `Sources/ZSlice/Core/Project.swift` | printdeck.yml projects: the files of the plates, and the load of the core. |
| `Sources/ZSlice/Core/SavedSettings.swift` | The settings after a restart. |
| `Sources/ZSlice/Core/Gzip.swift` | A gzip file of some bytes, for the estimate of a printdeck. |
| `Sources/ZSlice/Core/Settings.swift` | The setting infos, values, sources, effects, and value texts, from the core. |
| `Sources/ZSlice/Views/MetalSliceView.swift` | The 3D view: an `NSView` over a `CAMetalLayer`, its display link, and the input. |
| `Sources/ZSlice/Render/FrameRenderer.swift` | Draws the frame data of the core with Metal. |
| `Sources/ZSlice/Render/LayerRenderer.swift` | Draws the 2D view of one layer with Metal: the bed, the outline (a stencil fill), and the beads as strokes. |
| `Sources/ZSlice/Render/Shaders.swift` | The Metal shaders. They port `src/render/shaders/*`, and the 2D shaders of `web/app/gl.js`. |
| `Sources/ZSlice/Views/DocumentWindow.swift` | The window: the 3D view, the scrub bar, and the print card. |
| `Sources/ZSlice/Views/LineCard.swift` | The card of a selected line, next to it in the view. |
| `Sources/ZSlice/Views/ToolStrip.swift` | The tool strip, and the measure tape with its readout. |
| `Sources/ZSlice/Views/Legend.swift` | The legend of the colors: the line types to show or fade, or the range of a ramp. |
| `Sources/ZSlice/Views/PrintFacts.swift` | The main settings of the print on the print card, each with a popover of editors. |
| `Sources/ZSlice/Views/PlateBar.swift` | The plate bar: the plate before and after, all plates, a new plate, and Remove. |
| `Sources/ZSlice/Views/PartCard.swift` | The card of a selected part. |
| `Sources/ZSlice/Views/ProjectPage.swift` | The Project page of the drawer: the plates and the parts of a project. |
| `Sources/ZSlice/Views/Timeline.swift` | The timeline of the history at the top of the view. |
| `Sources/ZSlice/Views/Licenses.swift` | Help > Licenses: the components of the core and the frameworks of macOS. |
| `Sources/ZSlice/Views/LayerSlider.swift` | The slider with two knobs for the layers that show. |
| `Sources/ZSlice/Views/HistoryPage.swift` | The History page of the drawer: the steps, the newest first, with their changes. |
| `Sources/ZSlice/Views/SettingsInspector.swift` | The settings drawer: the sections, the settings with their editors, the page of a setting, and the search. |

## Plates

A window has a plate set of the core (`zs_set`): one `zs_app` for each plate, with its own settings, parts, undo list, and slice. The active plate is the plate that the window shows and changes. The set slices the other plates in the background, the active plate first, and `zs_set_view_sync` shows all plates in a row in one view. A click on another plate makes it active. The plate bar has the plate before and after (`[` and `]`), All (Home), a new plate (File > New Plate, Option-Command-N), and Remove (it asks first for a plate with parts: the plates are not in the undo list). File > Add Models to the Plate (Shift-Command-I) adds parts to the active plate. A drag or a turn of a part calls `zs_set_changed_held`, and `zs_set_release` at the end, so the part slices once.

## Threads

The core slices on its own threads, and calls the event function there. The event function only posts the event to the main queue (`DispatchQueue.main.async`). All calls into the core run on the main thread. A change calls `zs_app_request_slice`, which stops a slice that runs and starts a new one, so the main thread never waits for a slice.

## The 3D view

On macOS the core does not draw. The view is a `zs_view` with no surface (`ZS_SURFACE_FRAME`). The core uses its frame backend (`src/render/web.zig`), the same as the web app. After each `zs_view_draw`, the view keeps the frame data (`zs_view_web_frame`): the bead instances, the bead mesh and its levels of detail, the draw list, the grid, the bed model, the other plates, and the push constants. `FrameRenderer` reads that data and makes the draw calls of the Vulkan backend, as `web/app/gl.js` does with WebGL2.

- The camera, the pick, the culling, and the levels of detail stay in the core.
- A buffer goes to the GPU again only when its generation changes. Each upload makes a new `MTLBuffer`, so a frame in flight keeps its old buffer.
- The core makes its matrices for the clip space of Vulkan (y down, depth 0 to 1). Each Metal vertex shader turns y over.
- The drawable format is UNORM: the shaders work in sRGB values, as in the Vulkan backend. The view draws with 4x multisampling.
- The app compiles the shader source when it starts, so the build needs no Metal tools.
- The view draws only after a change. Its display link (`NSView.displayLink`, macOS 14) runs while a frame waits or the camera moves, and pauses after that.
- The view passes pixels to the core: points times the backing scale, with the origin at the top left (the view is flipped).
- The dark look of the view follows the appearance of the window (`zs_view_set_dark`).

### The 2D page

The 2D page shows one layer from the top: the top layer of the layer slider. It uses the same bead buffer on the GPU as the 3D page, so a new layer only changes the range of a draw. The outlines of all layers (`zs_view_outlines`) go to the GPU once for each slice, as fans of triangles. The stencil buffer fills them by the nonzero rule. The toolbar of the window switches the page, and so do View > 3D View (Command-1) and View > 2D Layer View (Command-2). The app keeps the choice for the next window. On the 2D page, a drag pans, the wheel and a pinch zoom toward the pointer, and a double click fits the part (View > Fit the Part, Command-0).

### The settings drawer

The drawer of the other apps is a SwiftUI inspector at the right of the window. N in the view, the toolbar button, or View > Show Settings (Option-Command-I) shows it and hides it, and the app keeps the choice. A Mac inspector always sits beside the content, so the drawer has no Pin: it is always pinned. Its pages are those of `web/app/settings.js`: the sections of each group, the settings of a section (each with a switch, a menu, or a field with its unit), and the page of one setting (its slider, its formula, its source with Reset, its help, and the lines that it changes with their share of the print time). The search field finds settings by name or help text.

The view shows the lines that the page points at, and fades the others (`zs_view_focus`), on the 3D and the 2D page. A pointer over a row shows the lines of that row. A hidden drawer shows the whole print. A field sends a number after a pause of 450 ms in the typing, on Return, or with the up and down arrow keys; the plate then slices again.

### Undo and the history

The core keeps the undo list of each plate (`zs_app_history_*`). Each change through the C API notes its key. The app commits a step 400 ms after the last change, and it tells the core which setting editor has the focus, so an edit of one setting is one step.

The `UndoManager` of the plate mirrors the list: each step before the step now is one undo action, and each step after it one redo action. An undo action calls `zs_app_history_undo` and registers the redo action, as AppKit expects. So Edit > Undo and Redo (Command-Z and Shift-Command-Z) have the titles of a Mac app ("Undo Walls"). A text field that edits keeps its own undo. A click on a step of the History page goes to it through the undo and redo actions, so both lists stay right. When the list changes in another way (a step amended or dropped, or the history cleared after a step), the app makes the undo actions again. After an undo, the editors read the values again, and the plate slices again.

The timeline at the top of the view has Undo, Redo, a mark for each step in the color of its kind, and the count; a click on a mark goes to that step. The History page of the drawer lists the steps, the newest first, with their changes in words. The arrow button of a change undoes only that change (`zs_app_history_revert`). The menu of a step clears the history after it.

### The selected line and its card

A click on a line selects it: `zs_view_pick_segment` on the 3D page, and `zs_view_pick_layer` in mm on the 2D page. The view shows the path in yellow and the segment in orange. The card of the line opens next to the click. It shows the feature and the layer, the planned speed, the real speed, and the flow, why the line is slow (`zs_inspect.slow_text`), its size (`zs_app_measure`), and the four settings that matter most for it (`zs_app_inspect_picks`), each with its reason and a live editor. "Fade the Others" shows the other lines as ghosts (`zs_view_isolate`), and the app keeps the choice. "All Settings…" opens the drawer on all the settings that change the line. A drag of the head of the card moves it.

After a new slice, the app finds the same line again: it keeps the layer, the feature, and the middle point of the line, and `zs_app_pick_feature` gives the nearest line of the same feature there. With a selected line, Left and Right (or h and l) step along the print (Shift: a whole line, `zs_view_step`), Up and Down (or k and j) go to the nearest line on the layer above or below (`zs_view_nearest_on_layer`), C shows the layers up to the line, and Esc clears the selection. The layer slider follows the selection.

### The tools and the colors

The tool strip at the left picks the tool of the mouse; each tool has a key. Select (S) selects a line. Move (M) moves a part with a drag: the frame of the part follows the pointer at once (`zs_view_part_box`), the core gets the place at most each 60 ms, and the part slices once, at the end of the drag. Command and a drag move a part in any tool, and Command and the wheel turn the selected part by 15°. Turn (R) turns the selected part with the keys: Left and Right about Z, Up and Down about X, Page Up and Page Down about Y (15°, Shift: 5°). Measure (T) puts a tape between two points (`zs_view_surface_point`); a click on a circle or an arc measures from its center (`zs_app_measure`); the core draws the tape in 3D (`zs_view_set_measure`), and a readout floats over its middle.

The toolbar picks the colors of the lines (`zs_view_set_mode`): the filament, one color for each line type, or a ramp of the speed, the flow, the layer time, or the line width. The legend lists the line types; a click shows or fades one (`zs_view_focus`), and Option-click shows only it.

The print card shows the main settings of the print as buttons. Each opens a popover with live editors and a slider. A slider sends its value at most each 90 ms during a drag, so the view follows the drag. The card keeps the last numbers while a new slice runs.

The controls of the window are overlays on the edges of the content area, so a narrow window (with the drawer open) shrinks the scrub bar, and no control goes out of the window.

### The search, the keys, Gaps, Check, and the context menu

`/` (or Command-F) opens the search of the settings and the actions over the view, with a live control for each setting, a slider for a number, and an eye that shows only the lines of a setting. `?` (or Help > Keyboard Shortcuts) opens the sheet of all the keys of the Mac app; the Mac app owns its table. Gaps (G) shows the gaps of the top layer, and a click on a gap opens the settings that can close it. Check lists the issues of the print, and a click goes to an issue. A right click with no drag, or Control and a click, opens the context menu of a line: the layers, the support marks, Copy for AI, and Reset the View.

### Input

The bindings are those of the GTK app, with the keys of a Mac:

- A left drag orbits.
- A right or middle drag pans. A two-finger press and drag on a trackpad is a right drag, so it pans too.
- A two-finger scroll on a trackpad zooms toward the pointer. So do the mouse wheel and a pinch.
- A double click on a side of the print turns the camera to face it (`zs_view_look_at_side`), at a distance for the size of the part there. A double click on no side resets the view.
- A right click with no drag opens the context menu, and so does Control-click.
- Command-click, Command-drag, and Command-scroll select, move, and turn a part (Ctrl on Linux).

## Native parts

The app uses the system parts of macOS where it can:

- SwiftUI document windows: the open panel, Open Recent, window tabs, and full screen.
- The menus of a Mac app, with Command keys, and Settings in the app menu.
- Materials (vibrancy), system fonts, and the accent color for the cards.
- The Keychain for the API keys of printers.
- `UndoManager`, wired to the history of the core.

## Development hooks

Like the GTK shell, the app reads some environment variables for development and screenshots:

- `ZSLICE_SNAPSHOT=path.png` writes the window to that PNG file, 1.5 s after the first load of a slice, so the camera and the other hooks are done. The 3D view comes from Metal and the controls from AppKit (`cacheDisplay`), so it needs no permission to record the screen.
- `ZSLICE_LAYERS=lo,hi` sets the layer range after the first slice (layer numbers from 1).
- `ZSLICE_TIME=t` shows the replay at t seconds after the first slice.
- `ZSLICE_VIEW=2d` (or `3d`) opens the window on that page.
- `ZSLICE_PANEL=1` shows the settings drawer, and `ZSLICE_SETTING=name` opens the page of that setting. `ZSLICE_PAGE=history` opens the History page.
- `ZSLICE_TOOL=measure` picks a tool, `ZSLICE_CLICKS="x,y;x,y"` clicks with it, and `ZSLICE_DRAG="x0,y0;x1,y1"` is a Command-drag.
- `ZSLICE_MODE=n` sets the colors (0 filament, 1 line type, 2 speed, 3 flow, 4 layer time, 5 line width).
- `ZSLICE_RESLICE=n` changes a setting after each slice, n times, to test time and memory. `ZSLICE_TIMING=1` logs the time of each slice.
- `ZSLICE_CUT=1` opens the Cut popover of a selected part; `ZSLICE_CUT=z` cuts it at z mm. `ZSLICE_MOVE=i` moves part i to a new plate. `ZSLICE_SAVE=path` saves the project file there.
- `ZSLICE_DOC_SAVE=path` and `ZSLICE_DOC_AUTOSAVE=1` change the wall count of an opened file, then undo and redo, and save or autosave through the NSDocument, with a log line for each step.
- `ZSLICE_TEST_PRINT=path` writes the test print of layers 10 to 12 (zs_app_debug_gcode).
- `ZSLICE_BAMBU=address:serial:code` (with an optional fourth field, the library id of the model, such as `bambu-lab-p1s`) runs the Bambu link (Bambu.swift) on the plate: the upload, the start, the status, the test, and a wrong code, with a log line for each. `ZSLICE_BAMBU_FTP_PORT` sets the FTPS port, for a test server that cannot have port 990. `macos/tools/fake_bambu.py` is such a server: FTPS and MQTT over TLS with a self-signed certificate.
- `ZSLICE_FARM="url;bambu:address:serial:code"` adds printers in a fresh run, for the Printers page (`ZSLICE_PAGE=printers`). `ZSLICE_SNAPSHOT_DELAY=s` waits s more seconds before the snapshot, for pages that wait on the network.
- `ZSLICE_EDIT=kind` edits the selected line (0: do not print it; 1: 90 % plastic), `ZSLICE_EDIT_UNDO=1` undoes it 3 s later, and each slice logs the edits.
- `ZSLICE_TOOL=support ZSLICE_CLICKS="x,y;..." ZSLICE_SUPPORT_CLOSE=1` draws a support area with the clicks and closes it.
- `ZSLICE_FLEET=path` adds the printers of a fleet file (tools/farm_sim writes fleet.json). `ZSLICE_ASSIGN="plate:printer;..."` assigns plates to printers.
- `ZSLICE_QUEUE=1` puts all plates in the queue of the farm 4 s after the start; with `ZSLICE_QUEUE_SEND=1` (tests only) it sends each proposal with no question.
- `ZSLICE_SIGN_TEST=1` signs the G-code of the plate, checks it (zs_verify_gcode), and checks a copy with one byte changed. In a fresh run (`ZSLICE_FRESH`) the signing key stays in memory, not in the Keychain.
- `ZSLICE_DECK_JSON=path` logs the printers that a printer.json of a printdeck with more than one printer gives.
- `ZSLICE_PICKER=1` opens the printer picker.
- `ZSLICE_TURN=deg` turns the selected part about X, lets it settle, and logs the note. `ZSLICE_SUPPORT=1` turns support on first. Select the part with `ZSLICE_TOOL=move ZSLICE_CLICKS=center`.
- `ZSLICE_SESSION=dir` keeps the session in that folder, also with `ZSLICE_FRESH` (which turns the session off without it). `ZSLICE_QUIT_AFTER=s` quits as Command-Q does, after s seconds. With `ZSLICE_TIMING=1`, the app logs the session reads and writes, and the time of the first frame with beads.
- `ZSLICE_RESLICE=1` changes the infill 3 times, one change after each slice, and logs the longest wait of the main thread. With `ZSLICE_TIMING=1`, it logs the time of each slice too.
- `ZSLICE_PAGE_FLIP=dir` turns the view, goes to 2D and back, and turns it again. It writes `a.png`, `b.png`, and `c.png` there: `a.png` and `b.png` must be the same.
- `ZSLICE_OPEN_AFTER=path` opens a file 3 s after the start, as File > Open does, and logs the windows (the empty window must give its place to the file).
- `ZSLICE_RECORD=path.mov` records a demo video of the window (Recorder.swift): a turn, the colors, the layer slider, the replay, and the 2D view, frame by frame at 30 frames a second.
- `ZSLICE_ADD_PLATE="path;path"` puts each file on a new plate after the first slice.
- `ZSLICE_SEARCH=text` opens the search, `ZSLICE_GAPS=1` and `ZSLICE_CHECK=1` turn on Gaps and Check, `ZSLICE_MENU="x,y;Title"` (or `center;Title`) runs an item of the context menu, and `ZSLICE_DARK=1` sets the dark look.
- `ZSLICE_DOUBLE_CLICK=x,y` is a double click at that point after the first slice.
- `ZSLICE_PICK=x,y` picks the line at that point of the view (in points) after the first slice, as a click does.
- `ZSLICE_SET="name=value;name=value"` makes each change a step after the first slice, and `ZSLICE_UNDO=n` then undoes n steps.

## Work that moves to the core

App logic goes in the core, so that the three shells do not each have a copy. Two parts of the app move there:

- The history of undo and redo: done (`src/app/history.zig`).
- The value text: done (`src/app/setting_text.zig`).
- The settings that the line card picks for a line: done (`zs_app_inspect_picks`).
- The turn of the camera to face the side under a double click: done (`zs_view_look_at_side`).
- The plate set: done (`zs_set`).

## Status and plan

The work goes in steps. Each step keeps `zig build test`, `zig build web`, and the GTK build working.

1. The core link and the 3D view: open a file, slice, and show the beads with Metal. Done.
2. The slicing UI: the print card and Export G-code, the layer slider, the replay, the 2D layer view, the settings drawer, and history and undo (done).
3. The tools (Select, Move, Turn, Measure, Gaps, Check), the line and part cards, the settings search, the shortcut sheet, the context menu, and a double click that faces a side (done).
4. Printers (the picker, the library, App Keys, printdeck, OctoPrint, Moonraker, discovery), printdeck.yml projects, the menus, drag and drop, and the user docs (done). The status of a printer comes from the core (`zs_printer_status_*`); the estimate of a printdeck is a POST of the gzipped G-code (`Gzip.swift`).

## The document

`ProjectDocument` (ZSliceApp.swift) is a `ReferenceFileDocument` of a `DocumentGroup`, so the window has the Save, Save As, Revert, Versions, and autosave of macOS. The core history stays the source of truth: `History` drives the UndoManager of the NSDocument, as it drove its own one before, and tells the document when the step now is or is not the step of the last save (the dot of the close button). Only the history of the active plate uses the UndoManager, and a switch of the plate makes its actions again.

SwiftUI calls `snapshot` on another thread, while the main thread waits for the save. So the model keeps the bytes of the project file (`zs_set_project_save`), made on the main thread when the window is idle (0.8 s after the last change, and after the slice), and `snapshot` returns the last copy. The copy writes all meshes, so it waits: it must not slow a slice. `snapshot` never waits for the main thread: that was a deadlock. A save of a copy older than the last change marks the document changed again when the new copy comes.

A model file (an STL, or a 3MF that `zs_project_file_is` does not know) becomes an untitled document after the load (`fileURL = nil`, the type 3MF, the name of the model), so a save never writes over the model.

## The Xcode project and signing

`macos/ZSlice.xcodeproj` builds the same app as the Swift package, as a real app target that Xcode can sign, archive, and notarize. XcodeGen (https://github.com/yonaskolb/XcodeGen) makes it from `macos/project.yml`; after a change of that file, run `xcodegen generate` in `macos/`, and commit both. The project:

- builds the core first (a script phase runs `build-core.sh`; it finds Zig 0.16 in `ZIG`, on the path, or in Homebrew, and keeps `lib/libzslice.a` as it is when the core did not change, so Xcode does not link again);
- uses the module map of the package (`Sources/CZslice`) and `lib/libzslice.a`;
- uses `Info.plist` of the package, with the bundle id `org.beetlebug.zslice`;
- copies `src/printers/beds` to `Resources/beds` after the build, before Xcode signs the app;
- has the hardened runtime, which notarization needs. The app is not sandboxed: the search of the network uses multicast UDP, which a sandboxed app may use only with an entitlement of Apple;
- builds for Apple silicon and Intel in a release and an archive.

Signing: `macos/Signing.xcconfig` signs ad hoc, so the project builds with no Apple account. To sign with your Developer ID, make `macos/Signing.local.xcconfig` (git ignores it):

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
```

Then Product > Archive in Xcode, and in the Organizer, Distribute App > Direct Distribution, which signs and notarizes the app. From the command line:

```sh
cd macos
xcodebuild -project ZSlice.xcodeproj -scheme ZSlice -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/zslice.xcarchive archive
```


## Quick Look

Two app extensions in `QuickLook/` are part of zslice.app. `project.yml` builds them.

- `ZSliceThumbnail` (`QLThumbnailProvider`) draws the icon of a file in Finder on the CPU: `zs_gcode_thumbnail_png` for G-code, and `zs_app_thumbnail_png` for a model (`Shared/Render.swift`).
- `ZSlicePreview` (`QLPreviewingController`) is the preview of the space bar. It has the 3D view of the app: `MetalSliceView.swift`, `Render/`, and `Core/CoreText.swift` are part of its target. A G-code file loads with `zs_view_load_gcode`. A model is sliced with the default settings (`zs_app_slice`), and loads with `zs_view_load` after `ZS_EVENT_SLICED`. The slider calls `zs_view_set_layer`.

Both read STL, 3MF, and G-code. The app declares the type `org.reprap.gcode` (`.gcode`, `.gco`) in `Info.plist`. macOS keeps its own previews for STL, so those win for an STL file.

The aggregate target `ZSliceCore` builds `lib/libzslice.a` before the app and the extensions, which all link it.

To test, build the app, then run `qlmanage -x -t file` for a thumbnail, and `qlmanage -x -p file` for a preview. Old builds of the app with the same extension ids can win: `pluginkit -mAvvv -p com.apple.quicklook.preview` lists them, and `pluginkit -r path.appex` removes one.

## The session

`Core/Session.swift` brings the app back exactly as it was after Command-Q or a crash (`zs_session_write`, `zs_session_read`).

- Each window has one session file in `Application Support/zslice/session`, and `index.json` keeps their order. A file goes to a temporary file first, then a rename.
- The app text of a session is the state of the window as JSON (`WindowState`): its frame, the page, the layer range, the tool, the colour mode, the open panes, the selected part, and the file of the document with its unsaved changes.
- A write comes 1.5 s after the last change of any window (the plates, a slice, the camera, the page), and not while a slice runs. Command-Q, and the Quit event of the Dock or a logout, write once more (`SessionStore.quit`). If that write works, the documents are marked as saved, so no "Save changes?" alert comes: the session has the changes. A window that the user closes leaves the session.
- At launch, the first empty window takes the first session, and each other session opens a window. The view reads the last scene of the active plate (`zs_set_plate_scene`, `zs_view_scene_read`) and the camera (`zs_view_set_camera`) at once. The slices run after that, and the first slice takes the layer range and the part of the session.
- Times on an M-series Mac for one window with pod.stl: the window opens about 400 ms after the start of the app (AppKit and SwiftUI), the session reads in about 30 ms, and the first frame with beads comes at about 460 to 490 ms. A write takes about 150 ms, mostly the meshes of the project file. The Metal shaders compile once for the app.
