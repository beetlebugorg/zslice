# 11. The macOS app (SwiftUI and Metal)

## Goal

Build the native Mac app in `macos/`: a SwiftUI and AppKit shell around the app core. The core keeps the frame data of the 3D view (`ZS_SURFACE_FRAME`), and the app draws it with Metal. The app is a document app with Save, Versions, and autosave, an exact session restore after Command-Q or a crash, the Keychain for API keys, Quick Look extensions, and a Bambu Lab link that sends prints.

## Read first

- [The macOS app internals](../docs/internals/macos.md): the build, the Xcode project and signing, each file, threads, plates, the document, the session, the 3D view, the window, cards, input, tools, printers, cameras, Quick Look, and the development hooks. It is the spec of this part.
- [The macOS app user guide](../docs/user/macos.md): the keys and menus of the Mac. It names Grab G and Label E. Its section "Grab a part" still says "The Grab tool (H)": that is older than the code.
- Part 09 of this folder: the window layout, the cards, and the keys follow the web app.

## Build

1. `macos/build-core.sh`: `zig build lib` for `aarch64-macos` and `x86_64-macos`, merged with `lipo`. Take the object out of each archive and make the archive again with `libtool`: the archive of Zig 0.16 does not align its object to 8 bytes, and the Apple tools skip it with no error. Set `-Dcompiler-rt` for the f128 helpers. Build the two cores at the same time: the LLVM code generation of one object uses about one core, so a clean build went from about 320 s to about 165 s on an 8-core Mac. A failed build prints its log.
2. `make-app.sh` builds the Swift package. `macos/project.yml` makes `ZSlice.xcodeproj` with XcodeGen. After a new Swift file, run `xcodegen generate`. The app has the hardened runtime and is not sandboxed (the network search uses multicast UDP).
3. `FrameRenderer` reads the frame data of the core and makes the draw calls of the Vulkan backend in Metal. Upload a buffer only when its generation changes. Compile the shader source at start, so the build needs no Metal tools. Turn y over in each vertex shader. Draw only after a change; the display link pauses after that.
4. The beads draw with `box_fragment` (no `discard_fragment`) and back-face culling. Focus and see-through passes use a second fragment function. A new selection uploads only the changed bead range.
5. `ProjectDocument` is a `ReferenceFileDocument`. The core history drives the UndoManager. The model keeps the bytes of the project file, made on the main thread when the window is idle (0.8 s after the last change and after the slice). `snapshot` returns the last copy and never waits for the main thread.
6. `Core/Session.swift`: the session of each window (part 14).
7. The window: a toolbar with the file button, the search field in the center (as on the web), then the printer menu, the Filament button, the Quality menu, Printers, Settings, and More at the right. The search field gives up its width before an item at the right cuts its label. At a narrow width, AppKit moves whole items to the » menu. One bottom bar as on the web. The settings drawer is a SwiftUI inspector, always pinned.
   - The search can also be a rail at the left of the view (beside the tool strip) or at the right (beside the layer slider), the height of the view, with the name of each setting over its control. The head of the results, the card, and the rails have a button for each other place. A card and a rail stay open until × or Esc.
   - A click in the view closes the results under the toolbar field. A drag to turn or pan keeps them.
8. Cards and panels with `cardPlace(avoiding:)`, `.panel()` frames, and spatial cards (`SpatialStore`, the rules of `web/app/spatial.js`).
9. The tools: Select (V), Move (M), Turn (R), Grab (G), Measure (T), Support (S), Label (E), Paint (P). The Mac keeps Move, Turn, and Grab as three tools; the transform tool of the web and GTK apps is not on the Mac yet. h and l step like the arrows: the segment before or after a selected line, else the nozzle back or on. Shift-H and Shift-L step a whole line. Gaps has no key; View > Show Gaps stays.
   - The open panel, a drop, and the Finder take `.step`, `.stp`, and `.obj`. The part card has Mirror X and Mirror Y. B and View > Hide the Bed hide the bed.
   - The range card has the row "This body" (part 05).
   - Labels: the handles on the surface, the smart guides drawn as thin lines (Option moves free), Place an SVG, an SVG dropped on a part, and the mode and relief on the card. A corner keeps the aspect (Shift: each axis on its own).
   - A printer with more than one nozzle shows a section for each nozzle after the first. The line card says which nozzle prints a line. Infill filament has the filament chips.
   - File > Calibrate, Import a Profile in the printer and quality menus, and Print Earlier and Print Later on the part card with one part at a time.
   - The search field is one soft shape, 22 points high, like the menus next to it, with no box inside. It shows its key (/) as plain text while it is closed, and × in the same slot while the results show. An open search has one accent outline. The results show at once on focus, with a line of help before the first letter, 640 points wide. The unit and the speed hint have columns of their own. The undock button is the card glyph of the web app. It shows on hover or while the search is open, and keeps its place, so the field does not change width. The labels of the Printers page, the project page, and the print card wrap.
   - The badge of the print is red for the problems and for a note, and says "2 refinements" in the accent color.
   - The bottom bar is one row: the plates, then Undo, Redo, and a History button with a clock, then the replay, then the print. Under 940 points the replay goes to a second row. The button counts the changes since the window opened or saved its file. A click or Command-Y opens the list in a popover. Each step has its glyph, its kind, its time, and Now or Go to. The 3D view ends at the top of the bar.
   - A failed slice says "Did not slice" in red in the bottom bar, with `zs_status_message`. A part that does not fit still slices. The bar says "Does not fit the printer", the details show `zs_app_plate_printable`, and Export and Print stay off. `ZS_ISSUE_FIT` has its icon in the Check.
   - The settings of each nozzle (`SettingInfo` reads the nozzle of each setting), the nozzle choice T0 to Tn, and the waste line of the filament list (part 05).
   - The document and the open panels take the type that macOS gives each model extension, and `Info.plist` lists the Bambu Studio types (`com.bambulab.3mf`, `com.bambulab.step`) for Open With.
   - The icon: `macos/make-icon.sh` writes the AppIcon set (16 to 512 pt at 1x and 2x) from `assets/icon`. The art is 824 of 1024 px, on the grid of macOS icons. The small art makes the 16 pt icons and 32 pt at 1x. `make-app.sh` makes `AppIcon.icns` for the app of the Swift package.
   - The draft slice first, with a work bar of 2 points. The exact slice waits while a draft slices. Another plate, or a plate that goes, gets the exact slice first.
   - `zslice://` links: the app gets a Get URL event. After the session is back, the key window checks the link with the core and asks in a sheet, with Cancel on Return. The download has no cookie, no credentials, and no proxy, and refuses a host with a local address before each request and each redirect.
10. Printers: `Core/PrinterLink.swift`, `Core/Bambu.swift`, `Core/Camera.swift`, `Core/FarmMonitor.swift` (part 13).
11. Quick Look: `ZSliceThumbnail` draws icons on the CPU (`zs_gcode_thumbnail_png`, `zs_app_thumbnail_png`). `ZSlicePreview` has the 3D view for the space bar preview of G-code, STL, and 3MF.

## Input on the Mac

- A left drag orbits. A right drag of a mouse orbits, as in Cura.
- Two fingers clicked down and slid on a trackpad pan. AppKit gives that as a right drag with the subtype `.touch`, so the Mac tells a trackpad from a mouse by the event.
- A middle drag, or Shift and a drag, pans. A two-finger scroll, the wheel, and a pinch zoom toward the pointer.
- A right click with no drag, or Control-click, opens the context menu.
- Command-click, Command-drag, and Command-scroll select, move, and turn a part.

## Lessons

- **Ask before a saved key goes to a new address.** A change of scheme, host, or port asks, with No as the default. No drops the key, Cancel keeps the old address and key, and a new origin drops the old https address. The address field is a draft until the edit ends, and Test the Connection asks first, because each of them can send the key.
- **Test a save with an empty active plate.** The project keeps the parts of the other plates, and it opens with the same plates.
- **Keep the line, the plate, and the camera in the core model.** A selected line is its key. A draft can miss that key, so a miss falls back to the nearest line of the same feature at the saved place, and the exact slice goes back to the first key and segment. A plate change is a request, and the camera target waits for its plate. Test a selection through a delete, an undo, and a redo.
- **Keep the print details inside their padding.** Filament rows wider than the card spilled over its padding and squeezed the spool mark. The card is 336 points wide, the rows have fixed columns, a head holds the close button, and the details scroll in a short window.
- **Show the layer of a line that a key selects.** With j, the line went down under layers that stayed visible. The top of the range now goes to the layer of the line, and an empty layer is passed.
- **Keep the reasons off the line card.** How the values come about (the planned and real speed, the flow, the reason for each pick, a slow-down, the flow limit, and the text of `zs_inspect.explain` last) is at the foot of the Selected Line page.
- A selected part was an index, so a delete or an undo could move the selection to another part. The Mac app now keeps stable ids in `zs_selection`, and reads each index from its id at the moment of use.

- **Write no session until the restore at launch is done.** A window gets its session, then waits for its NSWindow. A write in that time listed the new, empty window and removed the files of the last run, so a quit or a crash then lost the session. Count the sessions that windows took and did not restore yet. A change in that time writes once after the last restore.
- **`snapshot` must never wait for the main thread.** That was a deadlock ("Fix a save that locked the macOS app").
- A model file (an STL, or a 3MF that `zs_project_file_is` does not know) becomes an untitled document, so a save never writes over the model.
- Open an empty window at launch. Do not open the Open panel.
- Keep the main thread free after a slice. Keep the thinned tree dots until the trees or the camera change.
- Keep the cards off the panels of the view. Place the gap card by its measured size.
- Keep the search in the toolbar, with a way to undock it.
- Keep only the settings in the right pane.
- Keep the API key on its origin through redirects (`KeyRedirect`).
- Stop tracking the Finder state of macOS in git.
- **Split large literals for the Swift compiler.** The Debug build on the CI runner stopped: the compiler could not type-check the map of the feature colors in time. The colors now go through a function with typed steps.
- **Read the URL of a link with `zs_link_url`.** Swift does not import the long C array of the URL, so the Mac read it at offset 0 of the struct.
- Free H and L for the vim keys: Grab is G and Label is E (part 09).
- **Take the file types of other apps.** Bambu Studio claims `.3mf` and `.step` with types of its own, and macOS then types the files with them. The Mac app took only its own types, so it refused these files: "cannot open files in the STEP Model format". A project 3MF of another type saves as the 3MF of zslice.
- **Say why a plate did not slice in the bar.** A failed slice showed "Slicing…" or the numbers of an older slice, and its reason only in the closed details.
- The Mac app does not have the import from a model page, the Speed section, the regions of a body, or the transform tool yet ([model import](../docs/internals/model-import.md) says "Not yet" for the Mac).

## Acceptance checks

1. CI checks that the Xcode project lists each Swift file, builds it, opens a box, slices it, and writes a picture of its window.
2. The window opens about 400 ms after the start of the app, and the first frame with beads comes before the first slice (about 460 to 490 ms with `pod.stl` on an M-series Mac).
3. Command-Q and a start bring back each window with its plates, camera, page, and layer range, with no "Save changes?" alert.
4. `ZSLICE_RESTORE_DELAY=s` shows that no session file is written during the wait.
5. `qlmanage -x -p file.gcode` shows the 3D preview.
6. `ZSLICE_RIGHT_DRAG=1` (a mouse right drag) must orbit. `ZSLICE_RIGHT_DRAG=touch` (a trackpad) must pan. `ZSLICE_INPUT_LOG=1` logs the subtype of each right press on a real trackpad.
7. `ZSLICE_BAMBU_OUT` writes the `.gcode.3mf` of each slice of a Bambu Lab plate, as a send builds it.
