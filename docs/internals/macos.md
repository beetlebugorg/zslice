# The macOS app

The macOS app is a native shell over the Zig core, in `macos/`. It uses SwiftUI, AppKit where SwiftUI falls short, and Metal for the 3D view. Only the core is shared with the other apps. The app follows the layout plan in [One view](one-view.md), in the way a Mac app does it.

App logic goes in the core, so the three shells do not each have a copy. The shell draws widgets, moves bytes to and from the network and the files, and moves events to the main thread.

## Build

The app needs Zig 0.16 and the Swift 6 tools of Xcode (macOS 14 or later).

```sh
cd macos
ZIG=/path/to/zig-0.16/zig ./build-core.sh   # lib/libzslice.a, for arm64 and x86_64
./make-app.sh                                # build/zslice.app
open build/zslice.app
```

- **`build-core.sh`** runs `zig build lib` for `aarch64-macos` and `x86_64-macos`, and merges the two static libraries with `lipo`.
  - The archive of Zig 0.16 does not align its object to 8 bytes, and the Apple tools (`ld`, `lipo`, `libtool`) then skip the object with no error. So the script takes the object out of each archive and makes the archive again with `libtool` before `lipo`.
  - It sets `-Dcompiler-rt`, which puts the compiler-rt of Zig in the library: the Apple linker has no libgcc for the f128 helpers that `std.json` and `std.fmt.parseFloat` call.
  - A link error after a pull of the core means that `lib/libzslice.a` is old: run the script again.
- **`make-app.sh`** builds the Swift package (`swift build`), and makes the app bundle with `Info.plist` and an ad-hoc signature.
- **After a new Swift file**, run `xcodegen generate` in `macos/`: the Xcode project lists each file. `make-app.sh` stops with the names of the files that are not in it.

### The Xcode project and signing

`macos/ZSlice.xcodeproj` builds the same app as the Swift package, as a real app target that Xcode can sign, archive, and notarize. XcodeGen (https://github.com/yonaskolb/XcodeGen) makes it from `macos/project.yml`. After a change of that file, run `xcodegen generate` in `macos/`, and commit both. The project:

- builds the core first. A script phase runs `build-core.sh`. It finds Zig 0.16 in `ZIG`, on the path, or in Homebrew, and keeps `lib/libzslice.a` as it is when the core did not change, so Xcode does not link again.
- uses the module map of the package (`Sources/CZslice`) and `lib/libzslice.a`.
- uses `Info.plist` of the package, with the bundle id `org.beetlebug.zslice`.
- copies `src/printers/beds` to `Resources/beds` after the build, before Xcode signs the app.
- has the hardened runtime, which notarization needs. The app is not sandboxed: the search of the network uses multicast UDP, which a sandboxed app may use only with an entitlement of Apple.
- builds for Apple silicon and Intel in a release and an archive.

`macos/Signing.xcconfig` signs ad hoc, so the project builds with no Apple account. To sign with your Developer ID, make `macos/Signing.local.xcconfig` (git ignores it):

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

## The files

The package is `Package.swift`. `Sources/CZslice/module.modulemap` makes the C API of the core (`include/zslice-app.h`) the Swift module `CZslice`. Each source file starts with a comment that explains what it does.

**The app and its windows**

| File | What it does |
|---|---|
| `ZSliceApp.swift` | The app, its menus, and its document type. |
| `Core/SliceModel.swift` | The plates of a window (one `zs_set` of the core), the active plate, its state, and the events of the core. |
| `Core/Workspace.swift` | The model of a window: the plate, the 3D view, the layer range, the replay, the drawer, the keys of the view, and the test hooks. |
| `Core/ProjectFile.swift` | The project file: all the plates of a window in one .3mf. |
| `Core/Session.swift` | The session: the windows as they were after Command-Q or a crash. |
| `Core/SavedSettings.swift` | The settings after a restart, and `global.toml`. |
| `Core/Settings.swift` | The setting infos, values, sources, effects, and value texts, from the core. |
| `Core/Profiles.swift` | The Filament and Quality profiles. |
| `Core/History.swift` | The undo list of the core on the `UndoManager` of macOS. |
| `Core/HistoryCard.swift` | The card of a history step over its bubble. |
| `Core/Refinements.swift` | Your usual refinements. |
| `Core/Simulation.swift` | The print as it forms. |
| `Core/Checks.swift` | Gaps and Check. |
| `Core/Clipboard.swift` | Copy, cut, paste, and duplicate (`Clip`, `clipCopy`, `clipPaste`), and the plate items (`copyPlate`, `duplicatePlate`, `pasteAsPlate`). |
| `Core/ContextMenu.swift` | The context menu of the view. |
| `Core/Project.swift` | printdeck.yml projects, and projects from GitHub. |
| `Core/CoreText.swift` | The texts of the core: a C string, and the words for a status code. |
| `Core/Throttle.swift` | Runs an action at most once in an interval during a drag, and once more at the end. |
| `Core/Gzip.swift` | A gzip file of some bytes, for the estimate of a printdeck. |
| `Core/Recorder.swift` | A video of the window, for the docs and demos. |

**The tools**

| File | What it does |
|---|---|
| `Core/Tools.swift` | The tools of the view (Select, Move, Turn, Grab, Measure, Paint), the parts, and the part card. |
| `Core/Selection.swift` | The selected line: the pick, the highlight, the facts of the line card, the line after a new slice, and the keys of a line. |
| `Core/LayerRange.swift` | A range of layers: a drag of the Select tool, and Shift-K and Shift-J. |
| `Core/SupportPick.swift` | The support that the Select tool picked: a tree to drag, or the overhang of a grid support. |
| `Core/Support.swift` | The Support tool: areas, one click, and the hover. |
| `Core/SupportTrees.swift` | The tree editor of the Support tool. |
| `Core/PaintTool.swift` | The Paint tool, over the paint session of the core. |
| `Core/Filaments.swift` | The filaments of the plate, and the spools of a deck. |

**Printers**

| File | What it does |
|---|---|
| `Core/Printers.swift` | The library of printer models, the bed models, and the printers of the user (API keys in the Keychain). |
| `Core/PrinterLink.swift` | Print, upload, test, Get a Key, the status, the camera, and the printers of a deck, over HTTP (https first). The checks of a send. |
| `Core/Discovery.swift` | The printers on the network: the UDP of the mDNS search of the core. |
| `Core/Signing.swift` | The signature of each print, and the pins of https certificates. |
| `Core/Bambu.swift` | Bambu Lab printers in LAN mode: FTPS, MQTT, and a TLS stream with a pinned certificate. |
| `Core/FarmMonitor.swift` | The status of each printer, the queue of the farm, and its notifications. |
| `Core/Camera.swift` | The picture of a printer camera: MJPEG, snapshots, and the Bambu cameras. |
| `Core/H264Decoder.swift` | The H.264 frames of an RTSP camera, with VideoToolbox. |

**The views**

| File | What it does |
|---|---|
| `Views/DocumentWindow.swift` | The window: the 3D view, the overlays, the bottom bar, and the details. |
| `Views/MetalSliceView.swift` | The 3D view: an `NSView` over a `CAMetalLayer`, its display link, and the input. |
| `Views/ToolStrip.swift` | The tool strip, and the measure tape with its readout. |
| `Views/LayerSlider.swift` | The slider with two knobs for the layers that show. |
| `Views/PlateBar.swift` | The plate bar: the plate before and after, all plates, a new plate, and Remove. |
| `Views/PlateSigns.swift` | The signs of the plates on the bed (the image of their text), and the Open button of an empty plate. |
| `Views/Timeline.swift` | The history in the bottom bar: Undo, Redo, and a bubble for each step. |
| `Views/HistoryGlyph.swift` | The glyph of each kind of step. |
| `Views/HistoryCardView.swift` | The bubble, and the card of a step. |
| `Views/HistoryPage.swift` | The History popover: the steps, the newest first, with their changes, and the line edits. |
| `Views/LineCard.swift` | The card of a selected line, and the placement of the cards. |
| `Views/PartCard.swift` | The card of a selected part, or of several parts. |
| `Views/CutPopover.swift` | Cut, from the part card. |
| `Views/RangeCard.swift` | The card of a range of layers. |
| `Views/SupportCard.swift` | The card of the Support tool, and of a picked support. |
| `Views/PaintCard.swift` | The card of the Paint tool. |
| `Views/FilamentViews.swift` | The filament chips, and the list of the filaments. |
| `Views/PrintFacts.swift` | The main settings of the print in the details, each with a popover of editors. |
| `Views/SettingsInspector.swift` | The settings drawer: the sections, the settings with their editors, the page of a setting, and its search. |
| `Views/GcodeEditor.swift` | The editor of the start and the end G-code. |
| `Views/SearchOverlay.swift` | The search of settings and actions over the view. |
| `Views/ShortcutSheet.swift` | The sheet of all the keys. |
| `Views/Legend.swift` | The legend of the colors: the line types to show or fade, or the range of a ramp. |
| `Views/CheckViews.swift` | The views of Gaps and Check. |
| `Views/PrinterViews.swift` | The printer picker, the printer menu, the Filament button, the Quality menu, and the Printers page of Settings. |
| `Views/PairSheet.swift` | The key of a printer in one step, and Connect a Printdeck. |
| `Views/FarmPage.swift` | The Printers page. |
| `Views/CameraView.swift` | A camera picture, and its large view. |
| `Views/ProjectPage.swift` | The project sheet: the plates and the parts of a project. |
| `Views/Licenses.swift` | Help > Licenses: the parts of the core and the frameworks of macOS. |

**Rendering**

| File | What it does |
|---|---|
| `Render/FrameRenderer.swift` | Draws the frame data of the core with Metal, and the mesh of the Paint tool. |
| `Render/LayerRenderer.swift` | Draws the 2D view of one layer: the bed, the outline (a stencil fill), and the beads as strokes. |
| `Render/Shaders.swift` | The Metal shaders: ports of `src/render/shaders/*` and of the shaders of `web/app/gl.js`. |

## Threads

The core slices on its own threads, and calls the event function there. The event function only posts the event to the main queue (`DispatchQueue.main.async`). All calls into the core run on the main thread. A change calls `zs_app_request_slice`, which stops a slice that runs and starts a new one, so the main thread never waits for a slice.

## Plates, documents, and the session

### Plates

A window has a plate set of the core (`zs_set`): one `zs_app` for each plate, with its own settings, parts, undo list, and slice.

- The active plate is the plate that the window shows and changes. The set slices the other plates in the background, the active plate first.
- `zs_set_view_sync` shows all plates in a row in one view. A click on another plate makes it active.
- The plate bar has the plate before and after (`[` and `]`), All (Home), a new plate (File > New Plate, Option-Command-N), and Remove. Remove asks first for a plate with parts: the plates are not in the undo list.
- File > Add Models to the Plate (Shift-Command-I) adds parts to the active plate.
- A drag or a turn of a part calls `zs_set_changed_held`, and `zs_set_release` at the end, so the part slices once.

### The document

`ProjectDocument` (ZSliceApp.swift) is a `ReferenceFileDocument` of a `DocumentGroup`. So the window has the Save, Save As, Revert, Versions, and autosave of macOS.

- The core history stays the source of truth. `History` drives the UndoManager of the NSDocument, and tells the document when the step now is or is not the step of the last save (the dot of the close button). Only the history of the active plate uses the UndoManager; a switch of the plate makes its actions again.
- SwiftUI calls `snapshot` on another thread, while the main thread waits for the save. So the model keeps the bytes of the project file (`zs_set_project_save`), made on the main thread when the window is idle (0.8 s after the last change, and after the slice). `snapshot` returns the last copy, and never waits for the main thread: that was a deadlock. The copy writes all meshes, so it waits until the slice is done. A save of a copy older than the last change marks the document changed again when the new copy comes.
- A model file (an STL, or a 3MF that `zs_project_file_is` does not know) becomes an untitled document after the load (`fileURL = nil`, the type 3MF, the name of the model), so a save never writes over the model.

### The session

`Core/Session.swift` brings the app back exactly as it was after Command-Q or a crash (`zs_session_write`, `zs_session_read`).

- Each window has two files in `Application Support/zslice/session`: the session file of the core (`<id>.zss`: the plates and their scenes) and a view file (`<id>.json`: the camera and the state of the window). `index.json` keeps the order of the windows. A file goes to a temporary file first, then a rename.
- The state of a window is JSON (`WindowState`): its frame, the page, the layer range, the tool, the colour mode, the open panes, the selected part, the file of the document with its unsaved changes, and the camera.
- The view file comes 1 s after a move of the camera, the page, or the layers, on the main thread: it is small, and a move of the camera never writes the session file.
- The session file comes only after a change of the plates or a new slice, 1.5 s after the last one and not while a slice runs, on a background queue. The core reads each set under its lock, and keeps the compressed meshes that did not change.
- Command-Q, and the Quit event of the Dock or a logout, write both once more (`SessionStore.quit`). If that works, the documents are marked as saved, so no "Save changes?" alert comes: the session has the changes. A window that the user closes leaves the session.
- At launch, the first empty window takes the first session, and each other session opens a window. The view reads the last scene of the active plate (`zs_set_plate_scene`, `zs_view_scene_read`) and the camera (`zs_view_set_camera`) at once. The slices run after that, and the first slice takes the layer range and the part of the session.
- No file is written until each session of the last run is back in its window. A window takes its session (`takePending`), then waits for its NSWindow before it restores it. A write in that time listed the new, empty window, and removed the files of the last run, so a quit or a crash then lost the session. `SessionStore` counts the sessions taken and not yet restored; `restoreDone` comes after each restore, or when the window never comes. A change in that time writes once after the last restore. `ZSLICE_RESTORE_DELAY=s` makes the window wait, asks for a write, and logs `index.json` during the wait.
- Times on an M-series Mac for one window with pod.stl: the window opens about 400 ms after the start of the app (AppKit and SwiftUI), the session reads in about 30 ms, and the first frame with beads comes at about 460 to 490 ms. A session file takes about 30 ms for pod.stl and 250 to 290 ms for deck_body, on the background queue. The main thread waits at most about 50 ms during three re-slices of deck_body.

## The 3D view

On macOS the core does not draw. The view is a `zs_view` with no surface (`ZS_SURFACE_FRAME`). The core uses its frame backend (`src/render/web.zig`), the same as the web app. After each `zs_view_draw`, the view keeps the frame data (`zs_view_web_frame`): the bead instances, the bead mesh and its levels of detail, the draw list, the grid, the bed model, the other plates, and the push constants. `FrameRenderer` reads that data and makes the draw calls of the Vulkan backend, as `web/app/gl.js` does with WebGL2.

- The camera, the pick, the culling, and the levels of detail stay in the core.
- A buffer goes to the GPU again only when its generation changes. Each upload makes a new `MTLBuffer`, so a frame in flight keeps its old buffer.
- A new selection of many paths (a run, a lit body) changes only some beads: the frame gives their range (`patch_first` to `patch_end`) and the generation that it changes (`patch_from`). When the renderer has that generation and no frame of the 3D or the 2D page is on the GPU (`framesOnGPU`), it copies only those beads into its buffer: 0.01 ms, against 5 ms for the 1.8 million beads of deck_body on an M1. Else it uploads all of them.
- The renderer reads the pointer to the instances from the frame data of each frame: the core can swap it.
- The core makes its matrices for the clip space of Vulkan (y down, depth 0 to 1). Each Metal vertex shader turns y over.
- The drawable format is UNORM: the shaders work in sRGB values, as in the Vulkan backend. The view draws with 4x multisampling.
- The app compiles the shader source when it starts, so the build needs no Metal tools. The shaders compile once for the app.
- The view draws only after a change. Its display link (`NSView.displayLink`, macOS 14) runs while a frame waits or the camera moves, and pauses after that.
- The view passes pixels to the core: points times the backing scale, with the origin at the top left (the view is flipped).
- The dark look of the view follows the appearance of the window (`zs_view_set_dark`).

### The beads

The view draws each bead exactly as it will print: no coarser meshes while it moves. (The core uses its coarse mesh only for beads under 7 px wide, where it is exact to 1 px.)

- The plain beads use `box_fragment`, which has no `discard_fragment`, so the GPU tests the depth before the fragment runs. The focus and the see-through passes use `box_fragment_focus`. Zoomed in on deck_body during an orbit: 15.4 ms of GPU time a frame, against 16.8 ms with a discard.
- The opaque beads draw with back face culling: a bead is a closed mesh, so its back faces are always behind its front faces.
- The bed model draws in two passes (`drawBed`, as web/app/gl.js): the depth only, then the blended color where the depth is equal, with no depth write. Each pixel blends once, with the nearest face.
- Frame times on an M1 with a 4K display, orbiting for 3 s: resin_phenom_plate 6.6 ms of GPU time a frame and 110 frames a second at the start view, 11.8 ms and 70 frames a second zoomed in (14 steps); deck_body 5.6 and 11.2 ms. The frames over 8 ms of the main thread zoomed in wait in `nextDrawable` for the GPU; `zs_view_draw` takes under 0.1 ms.

### The signs of the plates

`Views/PlateSigns.swift` draws the text of all signs into one RGBA image, as web/app/signs.js: one row for each plate, with a clear row between them, its number and name, then its printer and its status, or its time and filament after a slice (`zs_set_plate_totals`). AppKit draws the text into a flipped CGContext, and the pixels go to straight alpha. `zs_view_set_signs` takes the image and the rect of each sign, with scale = the height of a sign / (46 × the backing scale). The core makes a flat quad on the bed for each sign; `FrameRenderer.drawSigns` draws them after the bed models with `bed_vertex` and `sign_fragment` (the color of the image, its alpha times the normal x), blended, with the depth test and no depth write. The image goes to the GPU with mipmaps when `sign_gen` changes. The app makes the image again only when its text or look changes: a key of the lines, the theme, the backing scale, and the accent color, checked after each frame. A click runs `zs_view_sign_at` before the plate pick.

### The mesh of the Paint tool

While the Paint tool is on, the frame draws the mesh of the part and the bed in place of the beads (`PaintMesh`, `paint_vertex` and `paint_fragment` in `Render/Shaders.swift`). Each corner of each triangle is a vertex, with its normal and its state. The pieces of the split triangles have a buffer of their own. A palette of 18 colors gives the color of each state.

### The 2D page

The 2D page shows one layer from the top: the top layer of the layer slider.

- It uses the same bead buffer on the GPU as the 3D page, so a new layer only changes the range of a draw.
- The outlines of all layers (`zs_view_outlines`) go to the GPU once for each slice, as fans of triangles. The stencil buffer fills them by the nonzero rule.
- The key 2 switches between the pages and 3 goes to the 3D page, as does the check item View > 2D View (Command-2). The 2D page shows a "2D View" sign at the top; a click on it goes to the 3D page. The app keeps the choice for the next window.
- On the 2D page, a drag pans, the wheel and a pinch zoom toward the pointer, and a double click fits the part (View > Fit the Part, Command-0).

## The window

The slice is the UI, so the chrome is small. The controls of the window are overlays on the edges of the content area. So a narrow window (with the drawer open) shrinks the scrub bar, and no control goes out of the window.

### The bars

- **The toolbar**: the file button (`FileButton`: the name of the document, a dot for unsaved changes, and a menu of the file), then the search field (`SearchToolbarItem`) at the left with it. At the right: the printer menu, the Filament button, and the Quality menu as one group, then Printers, Settings, and `MoreMenu`.
  - The window title is hidden from the toolbar on macOS 15 and later.
  - `QualityMenu` names a built-in quality, and "custom", with a capital (`Profiles.qualityTitle`). Under each built-in quality is its line of main points from `zs_quality_summary` (`Profiles.qualitySummary`): a second `Text` in the label of a menu item is its subtitle on macOS 14 and later.
  - No item is in the center: AppKit keeps a center item in the center, and a long printer name drew over it.
  - The labels of the menus keep their full size: at a narrow width, AppKit moves whole items to the » menu, and no label is cut with "…".
- **The tool strip** at the left has the tools in the order of the web app (V M R S H T P L), a divider, the colors of the lines (`ColorsButton`), Gaps, and Check (`CheckButtons`), in one box. `ToolGlyph` draws each icon from the SVG paths of the tool buttons of `web/app/index.html`, with the path reader of `HistoryGlyph`; `StripIcon` is the face of each button.
- Each card closes with `CloseMark`: a flat × at the size of the title, in a hit area of 24 points, on the first line of the title. A card title wraps; it never ends in "…".
- The note of the app (`workspace.note`) is a toast at the bottom of the view, over the bar, as in the web app.
- **`BottomBar`** is one bar, the width of the window and 70 points high: the plates and the history in the first row, the replay in the second. At the right end are the time (with the plastic, the cost, and the layers under it), a badge, and `PrintAction` (Export, or Print with Upload Only and Export in its menu).
  - A click on the time opens `PrintCard` above the bar as the details: the notes, the totals, the usual refinements, the main settings, and the filaments.
  - The badge says Check when there are notes (`noteCount`, red for a part off the bed or a failed slice, else orange), or else counts the refinements (blue).
  - A note does not open the details: they would cover the part (as on the web and in the GTK app).
- **The colors**: the palette picks the colors of the lines (`zs_view_set_mode`): the filament, one color for each line type, or a ramp of the speed, the flow, the layer time, or the line width. The legend lists the line types; a click shows or fades one (`zs_view_focus`), and Option-click shows only it.

### The cards and the panels

A card never covers the thing that was clicked, or a panel:

- `cardPlace(avoiding:)` puts a card on the first side of the screen box of that thing where it fits whole, in the order right, left, below, above. Then a free corner of the view, then the place with the least overlap. It keeps out of the tool strip and the layer slider.
- The box of a line is the whole clicked path (`zs_view_path_rect`). The box of a part has its turn rings (0.62 times its largest size, and 4 mm).
- The line card goes to a corner (`cardCorner`), and keeps its corner while that corner stays clear.
- The panels are the details, the check panel, the gap summary, and the card of a tool. Each marks itself with `.panel()`, a preference of its frame (`PanelFramesKey`). The window keeps the frames and the origin of the layer of the cards, so the placement can compare them. This is the rule of `freeArea` in web/app/place.js.
- The Turn, Grab, and Paint tools show no part card.
- **Spatial cards** (`Views/SpatialCards.swift`, as web/app/spatial.js): the line card, the part card, the range card, and the history card each keep one place and one size (`SpatialStore`, in `prefs` under `spatial.v1`). A drag of the head keeps the place, and the grip at the lower right corner keeps the size; the kept height is a least height. A card opens at its kept place, moved inside the view, unless there it covers the box of the clicked thing; then `cardPlace` places it for this time. A double click on the head forgets both.

### The settings drawer

The drawer of the other apps is a SwiftUI inspector at the right of the window. N in the view, the toolbar button, or View > Show Settings (Option-Command-I) shows it and hides it, and the app keeps the choice. A Mac inspector always sits beside the content, so the drawer has no Pin: it is always pinned.

- Its pages are those of `web/app/settings.js`: the sections of each group, the settings of a section (each with a switch, a menu, or a field with its unit), and the page of one setting (its slider, its formula, its source with Reset, its help (names and values in code marks show in a code font; tooltips and the search use the help without the marks), and the lines that it changes with their share of the print time). The search field finds settings by name or help text.
- The view shows the lines that the page points at, and fades the others (`zs_view_focus`), on the 3D and the 2D page. A pointer over a row shows the lines of that row. A hidden drawer shows the whole print.
- `OwnerBadge` (as web/app/settings.js): a list of one printer or filament section starts with a banner, "Printer · *name*" or "Filament · *name*" (`machine.name`, `filament.name`); a mixed list (a search, the search overlay) has the badge on each printer and filament row, and the page of a setting has it with a note. A print setting has none.
- A speed ratio (a setting `*_speed` that `zs_app_ratio_speed` knows) shows the speed that it gives on this printer next to the percent: "≈ 45 mm/s".
- A field sends a number after a pause of 450 ms in the typing, on Return, or with the up and down arrow keys; the plate then slices again.
- The details show the main settings of the print as buttons. Each opens a popover with live editors and a slider. A slider sends its value at most each 90 ms during a drag, so the view follows the drag. The details keep the last numbers while a new slice runs.

### The search, the keys, Gaps, Check, and the context menu

- The search of the settings and the actions (`SearchOverlay.swift`): its field is always in the toolbar, and `/` (or Command-F) gives it the focus. The results show under it, with a live control for each setting, a slider for a number, and an eye that shows only the lines of a setting. Return on a number or a text focuses its field (the `focusRequest` of `ValueField`); Return or Esc there gives the focus back to the search. The undock button makes the search a card with its own field (the spatial kind "search"); the app keeps the choice (`search.docked`). `SearchState` keeps the text, the selected row, and the place, for both fields.
- `?` (or Help > Keyboard Shortcuts) opens the sheet of all the keys of the Mac app. The Mac app owns its table. It has the groups of the web and Linux sheets, in two columns.
- The card of a gap keeps clear of the gap: `gapScreenBox` gives the screen box of its cells for `cardPlace(avoiding:)`. The place uses the measured size of the card (`gapCardSize`). A card taller than the free area of the view scrolls, so it stays clear of the bars too. `ZSLICE_GAPS=1 ZSLICE_GAP_OPEN=1` opens the card of the largest gap and logs both boxes and whether they overlap.
- Gaps (G) shows the gaps of the top layer, and a click on a gap opens the settings that can close it. Check lists the issues of the print, and a click goes to an issue.
- A right click with no drag, or Control and a click, opens the context menu. It fits what is under the pointer, as `web/app/context-menu.js` does: the support items on a support line, the part items on a line of a part, the plate items on the bed, and the view items each time. Remove This Support runs `zs_app_support_pick` up from the line in steps of 0.5 mm, puts a Block area on that overhang, runs `zs_app_mark_remove_near`, and ends the pick of the Select tool.

### Input

The bindings are those of the GTK app, with the keys of a Mac:

- A left drag orbits, and so does a right drag of a mouse, as in Cura. Two fingers clicked down and slid on a trackpad pan: AppKit gives that as a right drag with the subtype `.touch`, so the view tells a trackpad from a mouse by the event (the web and the GTK app guess it from the last scroll).
- A middle drag, or Shift and a drag, pans too.
- A two-finger scroll on a trackpad zooms toward the pointer. So do the mouse wheel and a pinch.
- A double click on a side of the print turns the camera to face it (`zs_view_look_at_side`), at a distance for the size of the part there. A double click on no side resets the view.
- A right click with no drag opens the context menu, and so does Control-click.
- Command-click, Command-drag, and Command-scroll select, move, and turn a part (Ctrl on Linux).
- The press of the left button goes to the window first (`sliceViewPress`). When the window takes it (a drag of a part, a range of layers, the Paint tool), the drag and the release go to the window. A press with no drag is a click: `sliceViewRelease` returns false, and the view handles the click and the double click.

## Undo and the history

The core keeps the undo list of each plate (`zs_app_history_*`). Each change through the C API notes its key. The app commits a step 400 ms after the last change. It tells the core which setting editor has the focus, so an edit of one setting is one step; `History.focusKey` keeps that setting too.

- **The UndoManager** of the plate mirrors the list: each step before the step now is one undo action, and each step after it one redo action. Each step registers as a top-level group of its own, with no grouping by event while it registers: in the group of an event that stayed open, the steps after it went into one group, and one undo took back all of them. An undo action calls `zs_app_history_undo` and registers the redo action, as AppKit expects. So Edit > Undo and Redo (Command-Z and Shift-Command-Z) have the titles of a Mac app ("Undo Walls"). A text field that edits keeps its own undo.
- **Copy and paste**: `ClipboardCommands` replaces the pasteboard group of the Edit menu. When the first responder is a text field (`NSText`), Cut, Copy, Paste, and Select All go to it. Else they call `clipCut`, `clipCopy`, and `clipPaste` of the workspace. A paste with no point uses the pointer over the view (`pointerInView`). The core keeps one clipboard of parts for the process (`zs_app_parts_copy`), so the parts paste on any plate of any window. `Clip.current` keeps the kind of the last copy, and the data of a label, an area, or layer changes. A label with no face under or over it says so, and adds no label.
- **A jump**: a click on a step goes to it through the undo and redo actions, so both lists stay right. When the list changes in another way (a step amended or dropped, or the history cleared after a step), the app makes the undo actions again. After an undo, the editors read the values again, and the plate slices again.
- **The timeline** in the bottom bar has Undo, Redo, a bubble for each step, and the count. A bubble has the color of its kind and its glyph: the SVG paths of web/app/history.js, read into SwiftUI paths (`HistoryGlyph`). The step now is 26 points, the others 22. A filament step (`zs_history_kind` "filament": a filament added, removed, or changed, or the filament of a part or the support) is indigo, with a spool from the side. A label step ("label": the text, the shapes, the size, the turn, or the depth of a label) is purple, with a tag.
- **The card of a step** opens after a hover of 350 ms on its bubble, over the bubble (`HistoryCard.swift`). It has the changes in words and an editor for each setting of the plate that the step changed: the change lines `scope\tkey\tbefore\tafter` whose scope has no ":" and is not one filament ("filament 2"), as web/app/history.js. It closes 400 ms after the pointer leaves the bubble and the card, unless one of its editors has the focus.
- **The History popover** lists the steps, the newest first, with their changes in words. The arrow button of a change undoes only that change (`zs_app_history_revert`). The menu of a step clears the history after it.

## The tools

The tool strip picks the tool of the mouse; each tool has a key.

### Select (V)

- **A line**: a click selects it: `zs_view_pick_segment` on the 3D page, and `zs_view_pick_layer` in mm on the 2D page. The view shows the path in yellow and the segment in orange.
- **The line card** shows the feature and the layer, the planned speed, the real speed, and the flow, why the line is slow (`zs_inspect.slow_text`), its size (`zs_app_measure`), and the settings that matter most for it (`zs_app_inspect_picks`), each with its reason and a live editor. "Fade the Others" shows the other lines as ghosts (`zs_view_isolate`), and the app keeps the choice. "All Settings…" opens the drawer on all the settings that change the line. A drag of the head of the card moves it (see the cards and the panels).
- **After a new slice**, the app finds the same line again: it keeps the layer, the feature, and the middle point of the line, and `zs_app_pick_feature` gives the nearest line of the same feature there.
- **The keys of a line**: Left and Right step along the print (Shift, or Shift-H and Shift-L: a whole line, `zs_view_step`). Up and Down (or k and j) go to the nearest line on the layer above or below (`zs_view_nearest_on_layer`); Control-F and Control-B go a page of layers. C shows the layers up to the line, and Esc clears the selection. The layer slider follows the selection.
- **A run**: Shift-click selects the line and lights its run (`pickRun`): `zs_app_path_run` gives the first and the last path from the retraction before the line to the next one on its layer, and `zs_view_highlight_more` lights the others (at most 20 000). A note gives the count. The next `showSelection` clears them.
- **Parts**: Command-Shift-click adds the part under the pointer to the selection of parts, or takes it out (`togglePart`, `zs_view_part_boxes`). In the Move and Turn tools, Shift-click does it too.
- **A range of layers**: a left drag that starts on a line lights a range of layers (`LayerRange.swift`), and Shift-K and Shift-J grow one with the keys. The card of the range edits settings in the scope of those layers.
  - From a line (the press of the drag, or the selected line of the keys), it lights only the body of that line in its part (`zs_view_light_connected`: a path joins when its box stays inside the lit box of the layer before, grown by 0.8 mm). With no line, the keys light the whole layers (`zs_view_light_layers`).
  - The body is a selection of many paths, and each load of the view clears it (a new slice, the simulated print, the dark look). After each load, `relightRange` finds the start line again (`RangeLine`: its layer, feature, and middle point, with `zs_app_pick_feature`) and lights the body again. The close of the card clears it (`zs_view_highlight_more` with no paths).
- **A support**: a click on a support line selects that support (`SupportPick.swift`).

### Move (M) and Turn (R)

- **Move** moves a part with a drag. The frame of the part follows the pointer at once (`zs_view_part_box`), the core gets the place at most each 60 ms, and the part slices once, at the end of the drag. Command and a drag move a part in any tool, and Command and the wheel turn the selected part by 15°.
- **Turn** turns the selected part with its rings, or with the keys: Left and Right about Z, Up and Down about X, Page Up and Page Down about Y (15°, Shift: 5°).
- **The fall of a part**: after a turn (the release of a ring, or 0.6 s after the last turn key), `settle(part:then:)` starts the fall of the part (`zs_app_fall_start`, the rigid body of src/rigid.zig). Each frame of the display link runs `zs_app_fall_step` with the frame time, and gives its turn, pivot, and move to `zs_view_part_preview`. The renderer draws the beads of that part with its own push constants (`part_draws`). At rest the core puts the part flush on its face (one history step), and `then` slices the plate; the new beads end the preview. A part that stands, or that support holds, does not fall, and a note says which.
- After each change of a setting or of the plates (support turned off, an area removed or made Block, a plate or a project opened), `checkPendingFall` asks the core for a part that cannot stand now (`zs_app_fall_pending`) and lets it fall, except during a turn, which runs its own fall.

### Grab (H)

The Grab tool takes a part with a click (`zs_view_surface_point`, `zs_app_grab_start`) and keeps it with no button held.

- The pointer moves the hand on the level plane 15 mm over the point held (`zs_view_plane_point`, `zs_app_grab_move`, from `sliceViewHover`).
- Option and a move turn the part (`zs_app_grab_turn`, 0.5° a point; Shift: 15° steps), and the wheel lifts the hand (1 to 200 mm).
- The next click, or Esc, lets go (`zs_app_grab_end`). From the press on, each frame runs `zs_app_fall_step`, as a fall does (`fallTick`); at rest the plate slices. A throw shows no fall note.

### Measure (T)

Measure puts a tape between two points (`zs_view_surface_point`). A click on a circle or an arc measures from its center (`zs_app_measure`). The core draws the tape in 3D (`zs_view_set_measure`), and a readout floats over its middle.

### Support (S)

- **One click**: the view tracks the pointer (`sliceViewHover`). At most once a frame, the window finds the point of the part under the pointer (`zs_view_surface_point`) and the overhang within 4 mm of it (`zs_app_support_pick`), and shows its outline as a selected area of the current kind. A click adds it (`zs_app_support_area_add` with its z range). A pick takes about 0.14 ms (cover_pegs.stl), so it runs on the main thread, with the other `zs_app` calls.
- **Areas point by point**: Option and a click draw an area point by point.
- **Trees** (`Core/SupportTrees.swift`), as on the web and Linux:
  - After each slice, while the tool is on, the window reads the nodes of each part (`zs_app_support_tree_nodes`) and draws them with `zs_view_support_add`: one dot for nodes closer than 7 points on the screen, the segments of the selected branch, and the ring of the selected node.
  - A press picks the ring of the selected node, then a dot, then a segment. During a drag the nodes follow the pointer at once.
  - The core gets the edit at most each 60 ms (`zs_app_support_tree_move_node`, `_set_radius`, `_move_branch`) and holds the slice (`zs_set_changed_held`). At most each 150 ms, `SliceModel.sliceHeldNow` releases it, so the support follows the drag; the history step stays open.
  - The release sends the last edit, slices, commits one history step, and runs the fall check. An edit sent while a slice runs gets `ZS_BUSY` and stays dirty for the next move or the release.

### Label (L)

`Core/Label.swift` is the model of a label (web/app/label.js, its top part): the JSON of the core as Codable structs, with each field optional so a field that the app does not show stays, and the math of its frame (the level right, the turn, a move into a new plane, the hit of a ray on its plane). `Core/LabelTool.swift` is the tool:

- A click on no label adds one where the ray of the view meets the part (`zs_label_place` on a paint session of the mesh of the part, one for each part, freed after each slice). A press on a label selects it and starts a drag; the drag places it again with `zs_label_place` and keeps the grab offset (Shift: in its plane).
- The labels show as decals: their outline in the plane (`zs_label_outline`, made again only when the shapes change), mapped onto the frame 0.05 mm out of the surface. `FrameRenderer.drawLabels` fills each label by the nonzero rule in the stencil: the fan of each path counts up or down by its winding, then the color goes where the count is not 0, and that pass sets the stencil back to 0 for the next label. The depth buffer has a stencil for this (`depth32Float_stencil8`). Metal has no fans, so `LabelDecals` makes their triangles.
- A change draws at once, and goes to the core 400 ms after the last change, or at the end of a drag or a scale (`zs_app_label_update`), as one step of the history; the plate slices. The labels are read again after each slice (an undo slices too).
- `Views/LabelCard.swift` is the card (the spatial kind "label"), the handle that scales the label, and the round handle that turns it (`LabelTurnHandle`). A drag of the turn handle turns the label by the angle of the pointer around its screen center. `labelTurnSign` reads the sense from the screen cross product of the right and up axes of the label, so the turn follows the pointer from the front or the back.

### Paint (P)

`Core/PaintTool.swift` reads the mesh of the part at its place (`zs_app_part_mesh`) and its paint (`zs_app_part_paint_get`), and makes a paint session of the core (`zs_paint_new`). The session does the regions, the hits along `zs_view_ray`, the fills, and the brush. Each hover and each step of the brush runs on the main thread, with no wait. The end of a click or a stroke gives the paint to the part (`zs_app_part_paint_set`), and the plate slices again.

## Filaments

`Core/Filaments.swift` reads the filaments of the plate (`zs_app_filament_*`) and the grams of each in the last slice (`zs_app_filament_stats`). The views read them again after each slice and each change of the list.

- `project.filament` has a chip editor (`FilamentChips`) in `SettingEditor`: on the part card and on the card of a range of layers. `project.support_filament` and `project.support_interface_filament` have the same editor, with a first chip for value 0: Part (the filament of the part) or Support (the support filament).
- On a printer with two nozzles (`machine.nozzles` = 2), each filament has its nozzle (`filament.nozzle`).
- **Use the Filaments** reads the spools of a deck printer (GET /api/plugin/printdeck, `filaments`). It adds or removes filaments at the end to match the count, then sets the material (upper case), the color, and on two nozzles the nozzle of each. A spool of the second nozzle (`"nozzle": "aux"`) stays out on a printer of one nozzle. No tray map goes out: the deck maps the trays at the start of the print. When the deck tells the nozzles of a Bambu Lab printer (`nozzles`, each with a code such as `HS01`), `PrinterLink.nozzleOfCode` sets `machine.nozzle_type` and `machine.nozzle_flow` from the first code it knows (as web/app/link.js): the first letter is the material (H hardened steel, S stainless steel, T tungsten carbide), the second the flow (H high flow, else standard). A code that it does not know keeps the settings.
- A Bambu Lab printer gets its .gcode.3mf from `zs_app_bambu_file_gcode`: the signed G-code of the shell, with the filaments, the time, and the grams of the last slice in the slice info.

## Printers

### The link

`Core/PrinterLink.swift` talks to printdeck and OctoPrint (the OctoPrint API) and Moonraker over HTTP.

- **Addresses**: a printdeck with a certificate has an https address too. The link tries the address that answered last, then https, then http. A network failure there goes on to the next address with no error. An answer of the printer, of any status, ends it. A refused certificate stops: no fall back to http.
- **The key and redirects**: URLSession keeps the headers of a request on a redirect, so each request with the API key goes through a session whose delegate drops `X-Api-Key` on a redirect to another origin (the scheme, the host, and the port): `KeyRedirect`, and the same method in `PinningDelegate` and in the stream reader of the camera. A redirect on the same origin keeps the key. The GTK app does the same (`linux/src/net/key-header.c`), and the web app refuses redirects.
- **A send** signs the G-code (`Signing.swift`), posts it, and counts as done only when the printer answers JSON with the stored file (`files.local`, or `done`).
- **The target of a send to a deck**: before each send to a printdeck, `checkDeckTarget` reads `/slicer/printer.json` at the root of the deck (the address with `/printers/<id>` taken off). With 2 or more printers, it stops the send when the path of the address is not in the list, when the saved deck name differs from the printer at that path, or when the name of the printer names another printer of the deck. Names match by their words (lower case, split at each character that is not a letter or a digit): a name names a deck printer when one has all the words of the other. An address of the deck itself with no saved deck name stops too, unless the name names the first printer. A list that does not read lets the send go. web/app/link.js has the same rules.
- **The status** of a printer: GET each path of `zs_printer_status_paths`, and give each reply to the core. A 401 or 403 marks a printer that needs a key.

### Keys and decks

- **The key in one step** (`PairSheet`): the App Keys flow of OctoPrint (`requestKey`). The printer asks its user "Allow zslice?", and the app gets a key of its own after Allow. The printer keeps a request for 2 minutes.
- **The printers of a deck**: after Allow, a printdeck lists its printers in `/slicer/printer.json`, the one at the root of the deck too. Each added printer gets the root of the deck and its path as its address, its name on the deck (`deckName`), the key, and the profile of its model (`PrinterLibrary.findModel`, as in web/app/printers.js). The hints go in the order of the model, the name on the deck, then the short label: a label such as "TAZ" alone matched a TAZ 6 for a TAZ Workhorse. A hint of one word matches no model. Of the 40 best of the search whose brand, name, and title have all the words of the hint, the one whose title ends in a nozzle nearest 0.5 mm wins, then the one with the fewest other words in its title. `ZSLICE_FIND_MODEL="TAZ Workhorse;TAZ"` logs the model of each hint.
- **Connect a Printdeck** (`ConnectDeckSheet`): the address of a deck, checked with GET /api/version (its text names printdeck), then a placeholder entry and `PairSheet` in a fresh mode. All the printers of the deck start checked. The placeholder goes, and the first printer added is the printer now.
- **The filament of each printer**: `usePrinter` saves the filament group (`zs_app_state_write`) in the `filament` field of the printer it leaves, and applies the saved text of the new printer (`zs_app_group_reset`, then `zs_app_profile_apply`; the filament before comes back if it does not load). A printer with no saved filament keeps the filament now.
- **The Keychain**: the API key of each printer, never in a file. A key goes when its printer goes. A test run (`ZSLICE_FRESH`) keeps the keys in memory, so its printers leave no Keychain items.

### Bambu Lab

`Core/Bambu.swift` does the network; the core makes the files and the messages (src/bambu.zig, src/mqtt.zig).

- **FTPS** with implicit TLS on port 990, the user "bblp", and the access code: TYPE I, PBSZ 0, PROT P, PASV, then STOR of the file on a data connection with TLS too.
- **MQTT** over TLS on port 8883, with the same login: CONNECT, SUBSCRIBE `device/<serial>/report`, PUBLISH to `device/<serial>/request`. The core makes the packets and reads the ones that come (`zs_mqtt_*`, `zs_bambu_push_all_packet`, `zs_bambu_start_packet`).
- **The certificate** of a Bambu printer has no authority. The app trusts it on the first connection, keeps its SHA-256 fingerprint (`bambu-pins.json`), and from then on accepts only that certificate at that address.
- A print starts only after a fresh confirmation of the user that the plate is clear, never from a timer or a retry.

### Cameras

`Core/Camera.swift` plays the camera of a printer while its view shows.

- **MJPEG**: URLSession reads a `multipart/x-mixed-replace` stream by itself: one response for the envelope, then one response and its data for each JPEG part (`StreamReader`).
- **Snapshots**: the feed loads the snapshot again every 5 seconds on a card, and each second in the large view.
- **Bambu P1 and A1**: the JPEG frames of port 6000 over `TLSStream` with the pin of the printer; the core cuts the frames (`zs_bambu_jpeg_reader`).
- **Bambu X1, H2, P2S, and X2D**: RTSP over TLS on port 322. The core runs the RTSP session (`zs_rtsp_*`, src/rtsp.zig) over the same `TLSStream`, and `H264Decoder` decodes its Annex B frames with VideoToolbox: the SPS and PPS make the format, and the other NAL units go in AVCC form.
- ImageIO decodes each JPEG off the main thread, with one frame on its way at a time. A card makes a CGImage of at most 4 pictures a second, and still decodes each H.264 frame.

### The farm

`Core/FarmMonitor.swift` reads each printer every 10 s while a Printers page shows, else every 30 s. The farm of the core (`zs_farm`) keeps the queue: the orders and their jobs, the state of each printer, the sends that it proposes, and its events, which become notifications of macOS. The farm never sends by itself: a send is a proposal that the user confirms.

## Refinements

`Core/Refinements.swift` keeps the store of refinements in `Application Support/zslice/refine.txt` and the hidden suggestions in `refine-hidden.json`. After each slice (0.8 s after the last one), the window merges the records of the plate (`zs_app_refine_records`, `zs_refine_merge`) under the id of the project of the plate, which the session keeps, and asks for suggestions (`zs_app_refine_suggest`). The words of a suggestion come from `zs_app_history_describe`. Apply is one history step (`zs_app_refine_apply`).

## Quick Look

Two app extensions in `QuickLook/` are part of zslice.app. `project.yml` builds them.

- `ZSliceThumbnail` (`QLThumbnailProvider`) draws the icon of a file in Finder on the CPU: `zs_gcode_thumbnail_png` for G-code, and `zs_app_thumbnail_png` for a model (`Shared/Render.swift`).
- `ZSlicePreview` (`QLPreviewingController`) is the preview of the space bar. It has the 3D view of the app: `MetalSliceView.swift`, `Render/`, and `Core/CoreText.swift` are part of its target. A G-code file loads with `zs_view_load_gcode`. A model is sliced with the default settings (`zs_app_slice`), and loads with `zs_view_load` after `ZS_EVENT_SLICED`. The slider calls `zs_view_set_layer`.

Both read STL, 3MF, and G-code. The app declares the type `org.reprap.gcode` (`.gcode`, `.gco`) in `Info.plist`. macOS keeps its own previews for STL, so those win for an STL file. The aggregate target `ZSliceCore` builds `lib/libzslice.a` before the app and the extensions, which all link it.

To test, build the app, then run `qlmanage -x -t file` for a thumbnail, and `qlmanage -x -p file` for a preview. Old builds of the app with the same extension ids can win: `pluginkit -mAvvv -p com.apple.quicklook.preview` lists them, and `pluginkit -r path.appex` removes one.

## Work in the core

These parts of the app moved to the core, so the three shells share them:

- The history of undo and redo (`src/app/history.zig`).
- The value text (`src/app/setting_text.zig`).
- The settings that the line card picks for a line (`zs_app_inspect_picks`).
- The turn of the camera to face the side under a double click (`zs_view_look_at_side`).
- The plate set (`zs_set`).
- The status of a printer (`zs_printer_status_*`), the farm (`zs_farm`), and the search of the network (`zs_discovery`).
- The paint session (`zs_paint_*`), the filaments (`zs_app_filament_*`), and the Bambu file, packets, and camera streams (`zs_bambu_*`, `zs_mqtt_*`, `zs_rtsp_*`).

## Development hooks

Like the GTK shell, the app reads environment variables for tests and screenshots. `ZSLICE_FRESH=1` makes a test run: the window state goes to its own defaults domain (`org.beetlebug.zslice.test`, empty at each start), and the keys, the signing key, the pins, and the session stay in memory. A test run never changes the app of the user.

**Windows, pages, and screenshots**

- `ZSLICE_SNAPSHOT=path.png` writes the window to that PNG file 1.5 s after the first load of a slice, so the camera and the other hooks are done. The 3D view comes from Metal and the controls from AppKit (`cacheDisplay`), so it needs no permission to record the screen. `ZSLICE_SNAPSHOT_DELAY=s` waits s more seconds, for pages that wait on the network.
- `ZSLICE_VIEW=2d` (or `3d`) opens the window on that page. `ZSLICE_PAGE=history`, `project`, or `printers` opens that page. `ZSLICE_PAGE_CLOSE=s` closes the Printers page after s seconds, to check that its cameras stop.
- `ZSLICE_PANEL=1` shows the settings drawer, and `ZSLICE_SETTING=name` opens the page of that setting (`@name`: only its section). `ZSLICE_DETAILS=1` opens the details.
- `ZSLICE_SEARCH=text` opens the search with that text (`ZSLICE_SEARCH_UNDOCK=1`: as a card). `ZSLICE_SEARCH_ENTER=name=value` then presses Return on the first result, types the value in its field, and presses Return again; it logs where the focus is after each step, and the value of the setting.
- `ZSLICE_GAPS=1` and `ZSLICE_CHECK=1` turn on Gaps and Check. `ZSLICE_MENU="x,y;Title"` (or `center;Title`) runs an item of the context menu. `ZSLICE_DARK=1` sets the dark look.
- `ZSLICE_PRINTER_LABEL=text` sets the label of the printer menu, and `ZSLICE_WIDTH=points` the width of the window (0: its narrowest), for tests of the toolbar.
- `ZSLICE_OPEN_AFTER=path` opens a file 3 s after the start, as File > Open does, and logs the windows (the empty window must give its place to the file).
- `ZSLICE_RECORD=path.mov` records a demo video of the window (Recorder.swift): a turn, the colors, the layer slider, the replay, and the 2D view, frame by frame at 30 frames a second.

**The view and the layers**

- `ZSLICE_LAYERS=lo,hi` sets the layer range after the first slice (layer numbers from 1). `ZSLICE_TIME=t` shows the replay at t seconds.
- `ZSLICE_MODE=n` sets the colors (0 filament, 1 line type, 2 speed, 3 flow, 4 layer time, 5 line width).
- `ZSLICE_PICK=x,y` picks the line at that point (in points) after the first slice, as a click does. `ZSLICE_DOUBLE_CLICK=x,y` is a double click there. `ZSLICE_CARD_LOG=1` logs the screen box of a clicked line.
- `ZSLICE_USE_PRINTERS="k[:color],..."` switches to printer k of the store in turn, 4 s apart, and then sets the color of the filament if one is given. `ZSLICE_SWITCH_LOG=1` logs the filament after each switch.
- `ZSLICE_LABEL_AT=x,y` (or `center`) opens the Label tool and clicks there, so a label goes on the face; `ZSLICE_LABEL_FILAMENTS=2` adds a filament first, `ZSLICE_LABEL_TEXT=text` sets its text, and it logs the label and its facts after the slice. `ZSLICE_LABEL_STEPS="turn:15,scale:1.5,drag:dx:dy,handle:40:shift,delete,undo,blur,set,coreundo"` (`handle:deg` drags the turn handle deg degrees around the label on the screen; `:shift` snaps) then runs each step 1.8 s apart and logs the label, the labels of the core, and the history after it. `ZSLICE_LABEL_LOG=1` logs why a click adds no label, and where a paste of a label lands. The label steps also take `copy`, `cut`, `paste` (`paste:x:y` at a point), and `dup`.
- `ZSLICE_CLIP="part:center,copy,paste,pasteat,cut,dup,copyplate,dupplate,pasteplate,undo,area,range:lo:hi,set:name=value,closerange,wait"` runs copy and paste steps 1.5 s apart (Clipboard.swift). It logs the parts, the plates, the selection, the clipboard of the core, the support areas, the overrides, the history, and the note after each.
- `ZSLICE_UNDO_LOG=1` logs each history step that the UndoManager gets, with its grouping level (it must be 0 after it).
- `ZSLICE_RIGHT_DRAG=1` sends a right drag of 100 points of a mouse to the view and logs whether the camera panned or orbited (it must orbit); `ZSLICE_RIGHT_DRAG=touch` sends it with the subtype of a trackpad (it must pan). `ZSLICE_INPUT_LOG=1` logs the subtype of each right press, to check a real trackpad.
- `ZSLICE_PICK_LATER="x,y;rx,y;cx,y;..."` picks each point in turn, one a second from 6 s after the start (`r`: the run of the line, as a Shift-click; `c`: a whole click of the view, as on a sign). With `ZSLICE_TIMING=1`, each upload of the beads is logged; a patch also checks that the whole buffer equals the beads of the core.
- `ZSLICE_SIGN_LOG=1` logs the lines of the signs each time the image is made. `ZSLICE_NO_SIGNS=1` sets no signs, to compare: with a sign, the start view of the core frames the sign too, so its camera looks a little nearer the front of the bed.
- `ZSLICE_RUN_AT=x,y` (or `center`) is a Shift-click of the Select tool; `ZSLICE_RUN_LOG=1` logs the run, and a plain pick 1.5 s later logs that the run is cleared.
- `ZSLICE_RANGE_DRAG="x0,y0;x1,y1"` drags over layers from a line with the press, move, and release of the view. `ZSLICE_RANGE_KEYS=n` presses Shift-K n times instead (with `ZSLICE_PICK` for the start line). Then the hook changes the infill of the range, so the body must light again after the slice. `ZSLICE_RANGE_LOG=1` logs each light, and `ZSLICE_RANGE_CLOSE=1` closes the card at the end.
- `ZSLICE_SPATIAL="kind:x,y,w,h;..."` keeps a place (the top left corner) and a size for a kind of card (`line`, `part`, `range`, `history`), as a drag and a resize do.
- `ZSLICE_KEYS=chars` types each key in the view, and logs the tool, the layers shown, the range card, and the selected line after it. An upper case letter has Shift, and `^x` is Control-x.
- `ZSLICE_LAYER_LOG=1` logs the layer count, and the times and path ends of the top three layers, after each slice.
- `ZSLICE_BED_BELOW=path.png` turns the view to look up from under the bed 2 s after the start, and writes the window there. Use it with `ZSLICE_PRINTER` set to a printer with a bed model.
- `ZSLICE_PAGE_FLIP=dir` turns the view, goes to 2D and back, and turns it again. It writes `a.png`, `b.png`, and `c.png` there: `a.png` and `b.png` must be the same.

**Settings, slices, and history**

- `ZSLICE_SET="name=value;name=value"` makes each change a step after the first slice, and `ZSLICE_UNDO=n` then undoes n steps.
- `ZSLICE_RESLICE=n` changes the wall count after each slice, n times, for tests of memory and time. Any value also changes the infill 3 times, one change after each slice, and logs the longest wait of the main thread; `ZSLICE_RESLICE=name=a,b,c` changes that setting to each value in place of the infill. With `ZSLICE_TIMING=1`, the app logs the time of each slice, of the work after it on the main thread, of the save copy, and of each frame over 8 ms.
- `ZSLICE_HISTORY_CARD=i` opens the card of history step i over its bubble 4 s after the start, and logs the settings that get an editor there.
- `ZSLICE_EDIT=kind` edits the selected line (0: do not print it; 1: 90 % plastic), `ZSLICE_EDIT_UNDO=1` undoes it 3 s later, and each slice logs the edits.
- `ZSLICE_SIM=1` logs the numbers of each simulated print, and its time after the slice. `ZSLICE_NO_SIM=1` turns off the simulation, to compare.
- `ZSLICE_REFINE=path` keeps the store of refinements in that file, also with `ZSLICE_FRESH`. `ZSLICE_REFINE_APPLY=1` applies the first suggestion and logs it.
- `ZSLICE_GCODE_AFTER=s:path` writes the G-code of the plate s seconds after the start, after the other hooks changed the plate (for example the prime tower of `ZSLICE_FILAMENT_TEST`).
- `ZSLICE_TEST_PRINT=path` writes the test print of layers 10 to 12 (`zs_app_debug_gcode`).
- `ZSLICE_SIGN_TEST=1` signs the G-code of the plate, checks it (`zs_verify_gcode`), and checks a copy with one byte changed.

**Tools and parts**

- `ZSLICE_TOOL=measure` picks a tool, `ZSLICE_CLICKS="x,y;x,y"` (or `center`) clicks with it, and `ZSLICE_DRAG="x0,y0;x1,y1"` is a Command-drag.
- `ZSLICE_SELECT_TEST` runs the Select tool, as in the GTK app:
  - `parts`: a copy of part 0, the plate arranged, and both parts selected.
  - `range lo hi [infill]`: the card of layers lo to hi, and an infill density for them.
  - `support x y [style]`: a click at x, y points, or at the first support line for `auto auto`; with a style, the support goes on first. `ZSLICE_SELECT_DEL=1` then presses Delete. `ZSLICE_SELECT_KIND=k` then runs Make It (0 grid, 1 tree, 2 pad), and logs the count of the areas before and after and the filament of the next slice.
- `ZSLICE_PLATE_HOME=k` makes plate k active 4 s after the start, runs Fit the Part 1.5 s later, and logs the camera target and the bounds of the print (use it with `ZSLICE_ADD_PLATE`).
- `ZSLICE_CUT=1` opens the Cut popover of a selected part; `ZSLICE_CUT=z` cuts it at z mm. `ZSLICE_MOVE=i` moves part i to a new plate. `ZSLICE_ADD_PLATE="path;path"` puts each file on a new plate after the first slice.
- `ZSLICE_TURN=deg` turns the selected part about X, lets it settle, and logs the note; `ZSLICE_SUPPORT=1` turns support on first. Select the part with `ZSLICE_TOOL=move ZSLICE_CLICKS=center`.
- `ZSLICE_TURN_KEYS=n` presses the Up arrow n times in the Turn tool, and logs the height of the part and the note 1.2 s later. `ZSLICE_DESELECT=1` picks the Select tool at once, as a click elsewhere does: the part must still fall.
- `ZSLICE_RING=axis,deg` presses a ring of the Turn tool, drags around the part until the turn is deg, and releases, as a user does.
- `ZSLICE_FALL_LOG=1` logs the start, the support, and the height of a part when its fall comes to rest. `ZSLICE_FALL_FRAMES=dir` writes a frame of the fall each 0.15 s.
- `ZSLICE_SUPPORT_OFF_AFTER=s` turns support off s seconds after the start, and logs the part 2.5 s later: a part that support held must fall.
- `ZSLICE_GRAB=1` takes the part at the center with the Grab tool, drags it 200 points to the right, lets go, and logs its place 3 s later.

**Support**

- `ZSLICE_TOOL=support ZSLICE_CLICKS="x,y;..." ZSLICE_SUPPORT_CLOSE=1` draws a support area with the clicks and closes it.
- `ZSLICE_REMOVE_SUPPORT=1` selects the longest support line of the layer at a third of the height, 3 s after the start, and runs Remove This Support; it logs the count of the areas before and after. `ZSLICE_REMOVE_SUPPORT=card` opens the card of that line and logs what it holds up.
- `ZSLICE_TREE_TEST=1` turns on tree support, picks the Support tool, drags a segment of the first tree 60 points to the right in 1 s, and logs each edit sent, the slices during the drag, the history steps, and the clamp.
- `ZSLICE_HOVER_SCAN=1` picks the Support tool, hovers over a grid of the view, logs the picks and their time, and clicks the first overhang.

**Filaments and paint**

- `ZSLICE_FILAMENT_TEST=lo:hi` opens the card of layers lo to hi, adds a red PETG filament, gives it those layers, and logs the grams of each filament and the changes after the slice.
- `ZSLICE_FILAMENT_LOG=1` logs the filaments of the plate (number, material, color) and their grams 5 s after the start. A painted 3MF of PrusaSlicer or Bambu Studio opens with its paint and its colors.
- `ZSLICE_FILAMENT_POPOVER=1` opens the popover of the Filament button.
- `ZSLICE_SUPPORT_FILAMENT=k` adds a second filament, turns support on everywhere, sets `project.support_filament` to k, and logs the grams of each filament and the changes.
- `ZSLICE_USE_FILAMENTS=1` runs Use the Filaments of the printer of the plate 4 s after the start, and logs its note, the filaments, and the nozzle type and flow.
- `ZSLICE_PAINT_TEST=smart` (or `brush`) adds a red filament, opens the Paint tool, and clicks (or strokes) the middle of the view. It logs the triangles, the region under the pointer, the size of the paint text, and the grams of each filament after the slice. The tool stays open for a screenshot. `ZSLICE_PAINT_SAVE=path` saves the painted project there.

**Printers and the farm**

- `ZSLICE_PICKER=1` opens the printer picker. `ZSLICE_STATUS_URL=url` is a printdeck printer of a test, with no key. `ZSLICE_DECK_JSON=path` logs the printers of a printer.json of a printdeck.
- `ZSLICE_FARM="url;bambu:address:serial:code[:model]"` adds printers in a fresh run. The model of a Bambu item is `bambu-lab-p1s` by default; `bambu-lab-x2d` has the RTSP camera.
- `ZSLICE_FLEET=path` adds the printers of a fleet file (tools/farm_sim writes fleet.json). A fleet file can give each printer a `model` (a library id) and a `deckName`. `ZSLICE_ASSIGN="plate:printer;..."` assigns plates to printers, and `ZSLICE_SAVE_AFTER=path` saves the project after that.
- `ZSLICE_QUEUE=1` puts all plates in the queue of the farm 4 s after the start. With `ZSLICE_QUEUE_SEND=1` it sends each proposal with no question.
- `ZSLICE_SEND_TO=k[:print]` sends the active plate to printer k of the store (or `all`: each one in turn), with no question, and logs each result. `ZSLICE_SEND_DELAY=s` waits s seconds first (4 by default).
- `ZSLICE_PAIR=url` adds a printdeck at url with no key and opens the sheet that gets its key. `ZSLICE_CONNECT_DECK=url` opens Connect a Printdeck with that address and connects. With either, `ZSLICE_PAIR_ADD=1` adds the printers of the deck and logs the list. The farm simulator answers with `--deck-printers 3 --appkeys-allow-after 2`.
- `ZSLICE_KEY_REMOVE=1` adds a printer with a key, removes it, and logs that the key went too.
- `ZSLICE_BAMBU=address:serial:code[:model]` runs the Bambu link on the plate: the upload, the start, the status, the test, and a wrong code, with a log line for each.
- `ZSLICE_BAMBU_FTP_PORT`, `ZSLICE_BAMBU_CAMERA_PORT`, and `ZSLICE_BAMBU_RTSP_PORT` set the ports of a Bambu printer (990, 6000, and 322), for a test server.

**Session and timing**

- `ZSLICE_SETTINGS_DIR=dir` keeps machine.toml, filament.toml, project.toml, and global.toml in that folder, also with `ZSLICE_FRESH` (which reads and writes none of them without it). A test of the move of the accelerations to the printer puts an old project.toml there.
- `ZSLICE_SESSION=dir` keeps the session in that folder, also with `ZSLICE_FRESH` (which turns the session off without it). `ZSLICE_QUIT_AFTER=s` quits as Command-Q does, after s seconds.
- `ZSLICE_DOC_SAVE=path` and `ZSLICE_DOC_AUTOSAVE=1` change the wall count of an opened file, then undo and redo, and save or autosave through the NSDocument, with a log line for each step. `ZSLICE_SAVE=path` saves the project file there.
- `ZSLICE_TIMING=1` logs the time of each slice, the session reads and writes, the time of the first frame with beads, and each frame over 8 ms with the part of it in `zs_view_draw`.
- `ZSLICE_STALLS=1` logs each wait of the main thread over 20 ms, with the time from the start. A timer runs each 5 ms in all run loop modes. Match the times with the other logs, or sample the app (`sample <pid>`) over the same span.
- `ZSLICE_ORBIT_TEST=n` zooms in n steps (any other value: 14), orbits for 3 s, and logs the mean GPU time and the frames a second.
- `ZSLICE_NO_CULL=1` draws the beads with no back face culling, and `ZSLICE_DISCARD_SHADER=1` draws the plain beads with the shader of a focus, to compare the picture and the GPU time.

### Test tools

`macos/tools/` has servers and tools for the tests of the network:

- `fake_bambu.py`: a Bambu Lab printer: FTPS, MQTT, and the JPEG camera of port 6000, over TLS with a self-signed certificate.
- `enc.swift`: encodes two pictures to H.264 with VideoToolbox, for `tools/fake_rtsps.py` (an RTSPS camera) on a Mac with no ffmpeg.
- `key_redirect.py`: two local servers for the test that the API key never follows a redirect to another origin.

`tools/farm_sim/` runs a farm of printers: printdeck, OctoPrint, and Moonraker, with App Keys, decks of many printers, and cameras.
