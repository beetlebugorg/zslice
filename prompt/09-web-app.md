# 09. The web app

## Goal

Build the web app at `web/app/`: the zslice window as one static page, with the core in WebAssembly. It needs no server code. It slices in a Web Worker, draws with WebGL2 on the main thread, slices with threads when the page is cross-origin isolated, and comes back exactly as it was after a reload. This shell defines the window layout. The GTK, Mac, and Windows apps match it.

## Read first

- [web/app/README.md](../web/app/README.md): the build, the tests, the security headers, the files, the two wasm instances, the threads, the 2D view, and the performance. Some lists at its end are older than the code. Where it and `docs/user/keys.md` or `web/app/app.js` differ, the code is correct.
- [One view](../docs/internals/one-view.md): the layout table and the keyboard rules. Its list of tool keys still names Label `L` and Gaps `G`. `docs/user/keys.md` is correct: Label is E, and Gaps has no key.
- [Keys and mouse](../docs/user/keys.md): the full key table. Match it.
- [JavaScript and WebAssembly](../docs/embedding/javascript.md), [The G-code viewer](../docs/embedding/viewer.md).
- [Privacy](../PRIVACY.md).
- "Speed in WebAssembly" in [Architecture](../docs/internals/architecture.md).

## Build

1. `zig build web` writes `zig-out/web/app`: the page, `zslice.wasm` (no threads), `zslice-mt.wasm` (threads), the bed models in `beds/`, and `printers.txt`.
2. Two wasm instances of one module: the worker instance has the app (`zs_app_new_web`) and the plate set. The main instance has the 3D view (`ZS_SURFACE_WEB`). The worker writes the scene as bytes (`zs_view_scene_write`), and the main view reads them. A scene over 4 MB goes in steps, one each frame.
3. `gl.js` draws the frame data of `src/render/web.zig` with WebGL2, with ports of the Vulkan shaders. A buffer goes to the GPU again only when its generation number changes.
4. Threads: a cross-origin isolated page loads `zslice-mt.wasm` on a shared memory (64 MiB at start, 2 GiB at most). The core worker starts one worker for each CPU but two, and each calls `zs_thread_run`. The module with threads has its own allocator (`src/wasm_heap.zig`).
5. The window ([one view layout](../docs/internals/one-view.md#the-layout)): one 3D view, a tool strip, floating cards, the settings search (`/`), a drawer that can be pinned, the dock, and the print card. The dock is one row: the plates, undo, redo, a history button, the replay, and the print. The history button opens the History list in a popover over it (also Ctrl+H). A number on the button counts the changes since the last open or save. The list has the glyph and the kind of each step, and a button that clears the later steps. The view ends at the top of the dock.
6. The tools and their keys: Select V, Move M (also R and G), Support S, Measure T, Paint P, Label E, Duplicate D. Move is one transform tool (`gizmo.js`, part 08). A drag of the part moves it on the bed and snaps it (Shift: no snap). A drag of an arrow moves it along X or Y, or lifts it. A drag of a ring turns it in steps of 15 degrees (Shift: 1). The beads follow the drag on each frame, a draft slice follows, and each drag is one history step. The arrows move a part 1 mm, Page Up and Page Down lift it, `[` and `]` turn it about Z, and Ctrl with the arrows turns it about X and Y. The part card has fields for X, Y, Z, and the three angles, and says why a part falls. The Grab and Turn buttons are gone. The Gaps button has no key. `?` opens the key sheet, from the same table as the menus and tooltips. `/` opens the search. `N` the settings panel. `2` and `3` the 2D and 3D views. `B` hides the bed. `[`, `]`, `F`, `Home` for plates. Up/K and Down/J for layers. Left/H and Right/L for the segment before and after (with no selection, the nozzle back or on). Shift+H and Shift+L for the line before and after. Shift+K and Shift+J select layers. Paint has the palette glyph. The line colors have a legend glyph.
7. Cards: the line card, the part card, the range card, the support card, the gap card, the label card, the history card. `place.js` places them. `spatial.js` keeps the place and the size of each kind of card. The line card has no reasons. The foot of the Selected page has the reasons, with setting links, and the core `explain` text as the last block.
8. The printer picker, the Printers page, the filaments, the Project tab, the Paint tool, the Label tool, the Support tool, Gaps, Check, undo and redo, and the history timeline.
9. The session in IndexedDB, written by the worker (part 14). The settings in `localStorage` (key `zslice.web.v1`).
10. Signing: a WebCrypto Ed25519 key in IndexedDB that no script can read signs each exported or sent file (`signing.js`).
11. The npm package: an embeddable G-code viewer for web pages (`web/npm`, `tools/npm_package.py`).
12. The Label tool: the handles and guides of part 08, the modes Ink, Raised, and Cut in with the relief on the card, and "Place an SVG…". An SVG file dropped on a part makes a label there.
13. The Calibrate menu (also in the search), "Import a profile..." in the printer and quality menus, and the place of a part in the print order on the part card (with one part at a time).
14. Open links (`web/app/openlink.js`): the Open menu registers `web+zslice://`, and the page reads `?open=<link or URL>`, then removes it from the address. The page checks the last URL after the browser follows redirects. A site with no CORS headers gets a message and a **Download the file** button.
15. A draft slice first after each change of a plate with a slice, and the exact slice 300 ms after the last change or at the end of a drag. While the view has a draft, the export and the print wait for the exact slice.
16. Preferences (main menu, Ctrl+, or Cmd+,): the slicer threads, the draft slices, the simulation after each slice, the theme, the first view, and the printers. The browser keeps the choices. The settings panel starts with the Speed section (part 02), and a line at its end points to Preferences.
16b. An edit of a printer address to a new scheme, host, or port asks before the saved key goes there (`askSendKey`). The default is No. Cancel keeps the old address and the key. Save project works from an empty plate when another plate has parts.
17. The settings of each nozzle (part 02), the Infill filament with the filament chips ("Part" for 0), the Filament row of the line card and the rows of the range card for a part of some layers (part 05), and the waste line of the filaments (part 05).
18. The import of a model ZIP file (`web/app/modelimport.js`). No app calls the API of a site. The page dialog shows the text of the core (`zs_import_page_text`): it names the site, and says how to get the ZIP file of the model. Then it opens the page. A ZIP file from Open or a drop shows the list of the core with check boxes. The checked files go on a new plate, and the worker call `spill` puts the parts that do not fit on more plates.
19. The icon: a favicon, a touch icon, and a manifest with 192 and 512 px icons (part 15).

## Numbers and rules that matter

- The headers of the host (in `web/app/README.md`): a strict Content-Security-Policy with `'wasm-unsafe-eval'`, `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: credentialless` (so printer cameras on other origins still load). Do not add `upgrade-insecure-requests`: it breaks printers at http addresses.
- The page loads only its own scripts, styles, fonts, and wasm. No fonts from Google.
- The main thread never waits for the worker. Bulk data goes as transferable ArrayBuffers. A frame allocates no JavaScript object.
- A 3DBenchy slices in about 0.5 s with threads, about 2.2 s with none. A warm-up slice of a small sphere at start makes the first real slice faster. A host must send a cache lifetime for the `.wasm` files so the browser keeps its compiled code.
- A long menu keeps its place and goes down to the bottom of the window. A menu with less than 240 px of room below its button moves up.
- The docked search results are 640 px wide. A speed ratio shows its speed ("≈ 75 mm/s") in a column of its own, so the controls of all rows line up.
- The undock button of the search is a card with a title bar (the path `M2.5 3.5h11v9h-11zM2.5 6.5h11` on a 16-unit grid). The glyph of an external link reads as "open in a new tab".
- A field sends its value after a pause in the typing. A slider sends values during a drag, so the view follows.
- The page keeps no copy of the selection. `selection.js` wraps the model in the wasm instance of the page. `tools.part`, `tools.parts`, `app.sel`, `app.seg`, and `app.activePlate` read it.
- The worker sends the table of the parts before the reply of a call. The client sends the generation and the stable part ids with each call.
- A pick and the start of a drag wait for no worker reply.

## Card rules

- **A card never covers the thing that was clicked, or a panel.** Place it on the first side of the screen box of the thing where it fits whole: right, left, below, above. Then a free corner, then the place with the least overlap. Keep it off the tool strip and the layer slider.
- The box of a line is the whole clicked path (`zs_view_path_rect`). The box of a part includes its turn rings.
- The Turn, Grab, and Paint tools show no part card. The web and GTK apps have no Turn and Grab tools now: the transform tool replaced them. The Mac and Windows apps still have them.
- A card that the user moved opens there the next time, unless there it covers the clicked thing. A grip at the lower right corner keeps its size. A double click on its head forgets both.
- The close button of each card is at its right edge, in line with the title.

## Lessons

- **Read wasm addresses as unsigned.** An export returns an address as a signed i32. Past 2 GB of memory the address is negative, and a DataView at it throws "RangeError: invalid or out-of-range index". Make each address unsigned with `>>> 0` in `alloc`, `cstr`, `text`, and each read.
- **Sync the memory size of each thread.** V8 keeps the size of the shared memory in each instance. A thread must `memory.grow` 0 pages before it uses memory that another thread added (`wasm_heap.sync`). Without it, a slice with threads never ended.
- **Keep library calls out of hot wasm code:** no 128-bit products, no float `@min`, `@max`, or `@round`.
- **Keep the session write off the main thread.** An IndexedDB put on the page held the main thread for 0.5 s with nine Benchies. The worker writes it.
- **Check each app file on each visit.** With cached scripts and a fresh `index.html`, a deploy broke the start. All app and doc files use `no-cache`. The bed models keep one day.
- Ask for `printer.json` only where a printer serves the app. The public site has none.
- Keep the API key on the printer: a request with the key follows no redirect (`test-link.mjs`).
- Stop a running slice when a change comes. Keep one app for each plate in the worker.
- Wait for the scene bytes of the worker in a sync of the plates. Making them on the UI thread cost 88 to 109 ms for six 3DBenchy copies.
- Fix the faults that pictures of the guide show: take screenshots of each page of the user guide and compare.
- **Show a long menu whole.** The main menu stopped at 70 % of the window height, so "About zslice" was under a scroll in a window 900 px high.
- **Line up the key sheet columns.** A column break drops the top margin of a group, so the first title of the second column was 10 px higher. The space over a group is now padding. The names and tags of the settings wrap in a narrow panel, in place of "…".
- **Put the history behind a button.** The timeline row of the dock used a full row for the marks of the steps.
- **Free H and L for the vim keys.** The owner wants the vim keys. H was Grab and L was Label. Now G is Grab and E is Label, and G no longer turns the gaps on. Change the key sheets, the tooltips, the search actions, and the docs in the same commit.
- **Never select from a late reply.** A reply of a turn or a move called `selectPart`, so it undid a newer click. A reply now updates the facts of the part. A reply that selects new parts checks `tools.stamp`.
- **Do not wait for the worker to start a drag.** The press asked the worker for the part, so a drag of a part waited about 700 ms for a slice. The pick is now in the page.
- **Let a click through a gizmo handle.** The rings and the arrows of a selected part took each click on a part behind them. A press and a release at one place is now a click on the part under the pointer.
- **Keep the part card off the other parts.** The card of one part took the clicks on the part next to it. The card now takes a side that leaves the other parts clear, if one exists.

## Acceptance checks

1. `node web/app/test-node.mjs zig-out/web/app/zslice.wasm part.stl`, `test-signing.mjs`, and `test-link.mjs` pass.
2. `python3 web/app/serve.py --csp` serves the page, and it starts with no console error.
3. `?model=part.stl&copies=8` opens eight parts, and an orbit holds 60 frames a second on a desktop GPU (`window.zslice.bench`).
4. Eight reloads in a row come back with the model, sliced, and the camera in place.
5. A click on a line opens its card beside the line, and the card covers no part of the line.
6. With `?threads=0` the slice uses one thread and gives the same G-code.
7. `node web/app/test-node.mjs` passes the link checks: a redirect to a local address, a web page, no name, a large file, no CORS, and a zslice project each stop.
8. `?open=<https URL of an STL>` asks first, then opens the model on a new plate if the plate has parts.
9. `node web/app/test-node.mjs` passes the import checks: the page check, the text for a page of each site, a ZIP list, a file of it, and the spill through the wasm module.
10. `node web/app/test-selection.mjs zig-out/web/app part.stl` passes in a memory cap: 100 selects after a move, Grab after 50 selects on two plates, each plate after a full plate, fast plate keys during a slice, the ring during a slice, undo and redo, and a line through a new slice.
