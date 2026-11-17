# The zslice web app

The web app is the window of the GTK shell (`linux/`) as a single page. It runs the zslice core in WebAssembly, in the browser. It needs no server code: any static file server works.

## Build and run

```sh
zig build web                      # zig-out/web/app: the page and zslice.wasm
python3 web/app/serve.py           # http://127.0.0.1:8000/
```

`serve.py` serves `zig-out/web/app` with the right MIME types (`application/wasm` for the module) and with no cache. Another folder or port: `python3 web/app/serve.py <folder> --port 8080`. Any other static server works too, if it sends `.wasm` as `application/wasm` and `.js` as `text/javascript`.

Open a model with the open button, with Ctrl+O, or drop a file on the preview. For tests, `?model=<url>` opens a model at the start, for example `http://127.0.0.1:8000/?model=part.stl` with `part.stl` in the served folder.

The browser needs WebGL2, module workers, and `WebAssembly.compileStreaming` (Chrome, Firefox, Safari of 2023 or later).

## Test

```sh
zig build web
node web/app/test-node.mjs zig-out/web/app/zslice.wasm part.stl
```

The test runs the code of the worker (`core.js`) and the view of the main thread (`view.js`) in Node, with no browser: settings, the saved state, a slice, the scene, and frames of the view.

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
| `view.js` | The 3D view of the main thread (`zs_view_*`) |
| `gl.js` | The WebGL2 drawing of the frame data of the view, with ports of the Vulkan shaders |
| `settings.js` | The Settings page: the sections, the settings, and the detail page |
| `layers.js` | The layer slider with two knobs |
| `menus.js` | The popup menus |
| `format.js` | The text of setting values, as the GTK shell shows them |
| `serve.py` | The dev server |
| `test-node.mjs` | The Node test |

### Two wasm instances

The page loads one module (`zslice.wasm`, the same file as `zig build wasm`) and makes two instances of it:

1. The worker instance has the app (`zs_app_new_web`). A slice runs on the thread of the worker, so the page stays responsive. The wasm build has no threads, so a slice takes longer than in the GTK app (the Benchy: about 3 s, the GTK app: 0.3 s).
2. The main instance has the 3D view (`zs_view_new` with `ZS_SURFACE_WEB`). The camera, the layer range, and the replay run here, with no wait for the worker.

After a slice, the view of the worker loads the slice (`zs_view_load`), and writes its beads as bytes (`zs_view_scene_write`). The worker sends the bytes to the page, and the main view reads them (`zs_view_scene_read`). The scene logic and the camera are the same code as in the GTK app (`src/render/view.zig`).

### The web backend of the view

The core cannot draw in a browser. Its web backend (`src/render/web.zig`) keeps the frame data in wasm memory: the bead instances, the bead mesh, the grid, the push constants, and the counts. After each `zs_view_draw`, `gl.js` reads them (`zs_view_web_frame`) and draws them with WebGL2: instanced draws of one bead mesh, as the Vulkan backend does. A buffer goes to the GPU again only when its generation number changes.

### Events

The app core sends its events (the slice progress) to the import `env.zs_web_event` of the module. The worker sends them on to the page.

### Saved settings

The settings persist in `localStorage` (key `zslice.web.v1`): the state text of each group (`zs_app_state_write`), the formulas, and the quality profile. At the start, the worker applies them in the order of the GTK shell.

## Not in the web app yet

- The 2D layer view.
- Printer links (printdeck, OctoPrint). A browser needs CORS headers on the printer for them.
- The Selected page (the inspector of a line), the gaps view, and the check.
- Part editing on the plate, more than one plate, and undo.
- Layer profiles, settings for one part, and profiles of the user.
- The comparison with Cura.
