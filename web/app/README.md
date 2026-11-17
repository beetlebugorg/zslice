# The zslice web app

The web app is the window of the GTK shell (`linux/`) as a single page. It runs the zslice core in WebAssembly, in the browser. It needs no server code: any static file server works.

## Build and run

```sh
zig build web                      # zig-out/web/app: the page and zslice.wasm
python3 web/app/serve.py           # http://127.0.0.1:8000/
```

`serve.py` serves `zig-out/web/app` with the right MIME types (`application/wasm` for the module) and with no cache. Another folder or port: `python3 web/app/serve.py <folder> --port 8080`. Any other static server works too, if it sends `.wasm` as `application/wasm` and `.js` as `text/javascript`.

Open a model with the open button, with Ctrl+O, or drop a file on the preview. For tests, `?model=<url>` opens a model at the start, for example `http://127.0.0.1:8000/?model=part.stl` with `part.stl` in the served folder. `&copies=8` puts 8 parts of it on the plate.

The browser needs WebGL2, module workers, and `WebAssembly.compileStreaming` (Chrome, Firefox, Safari of 2023 or later).

## Test

```sh
zig build web
node web/app/test-node.mjs zig-out/web/app/zslice.wasm part.stl
```

The test runs the code of the worker (`core.js`) and the view of the main thread (`view.js`) in Node, with no browser: settings, the saved state, a slice, the scene, frames of the view, the data of the 2D view, a pick, a step along the print, the Selected page of a line, the printer library, and a bed model in a frame.

The picker opens at the first visit (no printer set up). `?printers` opens it at the start, with `&q=text` (a search), `&pick=id` (a model), and `&step=2` (the second step) or `&step=add` (add the printer at once).

In a browser, `window.zslice` is a test hook: the state of the page, `select(path, seg)`, `showPage("2d")`, `bench(kind, frames)` (the frame times of an orbit, a pan, a zoom, or a move of the slider), and `benchPick()` (the time of picks over the view).

## How it works

The rule of `docs/app/README.md` holds: the app logic is in the core, and the web shell only draws widgets, reads and writes files, and moves events.

| File | What it has |
|---|---|
| `index.html`, `style.css` | The window: the header bar, the preview, and the panel, in the look of the GTK shell |
| `app.js` | The main thread: it builds the window, and connects the worker, the view, and the widgets |
| `worker.js` | The Web Worker. It owns the app core, and slices |
| `client.js` | The page side of the worker: calls with answers, and events |
| `core.js` | The app core (`zs_app_*`) for the worker |
| `wasm.js` | The wasm instance, and the helpers to call the C API |
| `view.js` | The 3D view of the main thread (`zs_view_*`), the pick, and the steps along the print |
| `gl.js` | The WebGL2 drawing of the frame data of the view, with ports of the Vulkan shaders, and of the 2D layer view |
| `view2d.js` | The 2D layer view: its camera (pan, zoom, fit) and its pick |
| `inspector.js` | The Selected page: the inspector of a line |
| `context-menu.js` | The entries of the context menu of the preview, in the order of the GTK menu |
| `settings.js` | The Settings page: the sections, the settings, and the detail page |
| `layers.js` | The layer slider with two knobs |
| `menus.js` | The popup menus, the context menu, and the popovers |
| `format.js` | The text of setting values, as the GTK shell shows them |
| `printers.js` | The printer picker: the printer library of the core (`printers.txt`, loaded when the picker opens), the search, the brands, the drawing of the build volume (with the bed texture on the plate), and the second step. Also the files of the bed model of the current printer (`bedFiles`) |
| `serve.py` | The dev server |
| `test-node.mjs` | The Node test |

### The bed model

`zig build web` copies the bed models of the printers (`src/printers/beds`, 10.5 MB in 736 files) to `beds/`. The wasm module has none of them. When the settings name a printer of the library (`machine.model`, or a `machine.name` that is the title of a model), `app.js` loads `printers.txt` in the main instance, asks the core for the names of the two files of its bed (`zs_printers_bed`), fetches them (about 20 to 60 kB), and gives them to the view (`zs_view_set_bed`). The core places the bed; `gl.js` uploads its vertices and its texture once (`bed_gen` of the frame), and draws it after the beads. A printer with no bed model keeps the grid alone.

### Two wasm instances

The page loads one module (`zslice.wasm`, the same file as `zig build wasm`) and makes two instances of it:

1. The worker instance has the app (`zs_app_new_web`). A slice runs on the thread of the worker, so the page stays responsive. The wasm build has no threads, so a slice takes longer than in the GTK app (the Benchy: about 3 s, the GTK app: 0.3 s).
2. The main instance has the 3D view (`zs_view_new` with `ZS_SURFACE_WEB`). The camera, the layer range, and the replay run here, with no wait for the worker.

After a slice, the view of the worker loads the slice (`zs_view_load`), and writes its beads as bytes (`zs_view_scene_write`). The worker sends the bytes to the page, and the main view reads them (`zs_view_scene_read`). The scene logic and the camera are the same code as in the GTK app (`src/render/view.zig`).

### The web backend of the view

The core cannot draw in a browser. Its web backend (`src/render/web.zig`) keeps the frame data in wasm memory: the bead instances, the bead mesh, the grid, the push constants, and the counts. After each `zs_view_draw`, `gl.js` reads them (`zs_view_web_frame`) and draws them with WebGL2: instanced draws of one bead mesh, as the Vulkan backend does. A buffer goes to the GPU again only when its generation number changes.

### The 2D layer view

The 2D view shows one layer from the top, as `linux/src/ui/layer-draw.c` draws it: the bed with its 10 mm grid, the outline of the layer in gray, and each bead in its feature color. The 2D and 3D buttons switch the views; the layer slider drives both. In 2D a drag pans, the wheel zooms at the pointer, and a double click fits the part. A replay, a step of h and l, and a change of the colors go to the 3D view, as in the GTK shell.

The data is in the view of the main thread, so a new layer needs no call to the worker. The beads of the 2D view are the instances of the 3D view on the GPU: `zs_view_layer_beads` gives the range of a layer, and one instanced draw draws it, as strokes with round ends. The outlines of all layers (`zs_view_outlines`) go to the GPU once for each slice, as fans of triangles; the stencil buffer fills them by the nonzero rule. The marks of a focus (seams, travel moves, retractions) come from `zs_view_layer_marks`.

### The selection and the Selected page

A click on a line selects it and its segment: `zs_view_pick_segment` in 3D (a pixel) and `zs_view_pick_layer` in 2D (a point in mm), both on the main thread. The view highlights the line (`zs_view_highlight`), and the worker answers the Selected page: `zs_app_inspect`, the values of the settings at the z of the line, and the support mark there. The page has the content of `linux/src/ui/inspector.c`: the three numbers with their reasons, the settings in sections with a filter, "Change for" (all layers, or the layers of the line: an override), and "How these values come about". "Copy for AI" copies the report of `zs_app_line_report` to the clipboard. After a new slice, the worker finds the same line again (`zs_app_pick_feature`).

The keys work as in `preview.c`: h and l (or Left and Right) step a segment along the print, with Shift a whole line; k and j (or Up and Down) go to the nearest line on the layer above or below; Escape clears the selection; C cuts the preview at the layer of the line, and Shift+C shows all layers. With no selection, the arrows move the nozzle and the layers. A step goes on from what the 3D view shows: the time of a replay, a scrub, or the step before. The steps are core calls of the view (`zs_view_step`, `zs_view_nearest_on_layer`, `zs_view_segment_at_time`).

### The context menu

A right click with no drag opens the context menu at the pointer (in 3D a right drag turns the view). The Menu key and Shift+F10 open it too. `context-menu.js` lists the entries in the order of `show_menu` in `linux/src/ui/view3d.c`, with the GTK action of each. The web app leaves out "New profile from here up" and "New profile from here down": it has no layer profiles yet.

### Performance

The main thread never waits for the worker, and the bulk data goes as transferable ArrayBuffers. A frame allocates no JavaScript object.

- A pick uses the pick index of the view (boxes of runs of 32 beads, and of layers), so it stays under a millisecond on a plate of eight Benchies (690000 beads).
- The 3D view draws a list of chunks of 512 beads (`zs_web_frame.draws`): the chunks out of the view drop out, and a bead less than 20 pixels wide draws with a mesh of 36 triangles for 100. The ranges draw from the top layers down, so the depth test drops hidden pixels early.
- A new layer in 2D changes the range of one draw: no upload.

On a desktop GPU (RTX 4070, Chromium with ANGLE on OpenGL), the frames of an orbit, a pan, a zoom, and a move of the slider hold 60 frames a second on the Benchy and on eight Benchies, in both views. The GPU time of a frame of eight Benchies is about 8 to 13 ms in 3D, and under 0.5 ms in 2D. These numbers come from one desktop GPU. In 3D, the cost of a full plate is the count of the beads (an instance each), so a weaker GPU has less room.

### Events

The app core sends its events (the slice progress) to the import `env.zs_web_event` of the module. The worker sends them on to the page.

### Saved settings

The settings persist in `localStorage` (key `zslice.web.v1`): the state text of each group (`zs_app_state_write`), the formulas, and the quality profile. At the start, the worker applies them in the order of the GTK shell.

## Not in the web app yet

- Printer links (printdeck, OctoPrint). A browser needs CORS headers on the printer for them. The printer picker keeps the address of a printer for later.
- The search of the network for printers: a browser cannot send mDNS packets.
- The gaps view, the check, and the multiple selection (Shift+click).
- Part editing on the plate (move, turn, remove), more than one plate, and undo. The context menu has the placement of a part, and the plate actions.
- Layer profiles, settings for one part, and profiles of the user.
- The comparison with Cura.
