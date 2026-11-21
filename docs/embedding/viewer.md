# The G-code viewer for a web page

The viewer shows a G-code file in the 3D view of zslice, on a canvas of your page. It reads G-code of zslice, CuraEngine, PrusaSlicer, OrcaSlicer, and Bambu Studio. It has the beads, the light, and the feature colors of the app and of the printdeck screen. It has no tools and no panel. Your page draws its own controls, for example a layer slider.

The viewer uses `zslice.wasm`, the module with no threads. It needs no worker and no cross-origin isolation.

## Try it

This page runs the viewer on a G-code file of zslice: the bridge test part of `tools/calib/parts/bridges.stl`. Drag in the view to turn it. Move the slider to show fewer layers. The code under the demo is the code that runs it.

```html live
<canvas id="gcode-view" style="width: 100%; height: 380px; touch-action: none"></canvas>
<label>Layer <input id="gcode-layer" type="range" min="1" value="1"> <output id="gcode-note">Loading…</output></label>
<script type="module">
  import { ZsliceView } from "../../zslice-view.js";

  const canvas = document.getElementById("gcode-view");
  const slider = document.getElementById("gcode-layer");
  const note = document.getElementById("gcode-note");
  try {
    const v = await ZsliceView.create(canvas);
    const info = await v.loadGcode(await fetch("bridges.gcode"), { bedX: 220, bedY: 220 });
    slider.max = info.layers;
    slider.value = info.layers;
    const show = () => {
      v.setLayer(slider.value - 1);
      note.textContent = `${slider.value} of ${info.layers}`;
    };
    slider.oninput = show;
    show();
  } catch (e) {
    note.textContent = `The viewer did not start: ${e.message}`;
  }
</script>
```

### Follow a print

A printer host gives the viewer the file position of the printer. The view shows the moves before it, with the nozzle at the last one. In this demo, ▶ moves the position through the file, as a printer does.

```html live
<canvas id="print-view" style="width: 100%; height: 380px; touch-action: none"></canvas>
<label><button id="print-play" type="button">▶</button> <input id="print-at" type="range" min="0" value="0"> <output id="print-note">Loading…</output></label>
<script type="module">
  import { ZsliceView } from "../../zslice-view.js";

  const canvas = document.getElementById("print-view");
  const slider = document.getElementById("print-at");
  const play = document.getElementById("print-play");
  const note = document.getElementById("print-note");
  try {
    const v = await ZsliceView.create(canvas);
    const info = await v.loadGcode(await fetch("bridges.gcode"), { bedX: 220, bedY: 220 });
    slider.max = info.size;
    const show = () => {
      v.setPosition(Number(slider.value));
      note.textContent = `${Math.round((100 * slider.value) / info.size)} %`;
    };
    slider.oninput = show;
    let timer = 0;
    play.onclick = () => {
      clearInterval(timer);
      if (Number(slider.value) >= info.size) slider.value = 0;
      timer = setInterval(() => {
        slider.value = Math.min(info.size, Number(slider.value) + info.size / 600);
        show();
        if (Number(slider.value) >= info.size) clearInterval(timer);
      }, 50);
    };
    show();
  } catch (e) {
    note.textContent = `The viewer did not start: ${e.message}`;
  }
</script>
```

On your site, change the two paths: the path of `zslice-view.js` in your folder, and the URL of your G-code file. The viewer loads `zslice.wasm` from the folder of `zslice-view.js`.

## Build

```sh
zig build web-view
```

The files go in `zig-out/web/view`:

| File | What it has |
|---|---|
| `zslice-view.js` | The module of the viewer. Import this file. |
| `view.js`, `gl.js`, `input.js`, `wasm.js` | The files of the web app that the viewer uses: the view, the WebGL2 drawing, the mouse and touch input, and the wasm helpers |
| `zslice.wasm` | The core |
| `example.html` | An example page: drop a G-code file on it |
| `LICENSE` | AGPL-3.0-or-later |

Put all files in one folder of your site. The npm package `@beetlebugorg/zslice` has them in `view/`.

## Serve

- Send `zslice.wasm` as `application/wasm`. With another type, the viewer still works, but the browser cannot compile the module while it downloads.
- Send the `.js` files as `text/javascript`.
- A Content-Security-Policy needs `script-src 'self' 'wasm-unsafe-eval'`.

To try the example:

```sh
cd zig-out/web/view
python3 -m http.server 8000
```

Then open `http://127.0.0.1:8000/example.html`. `?gcode=<url>` loads a file at the start.

## Use

```js
import { ZsliceView } from "./zslice/zslice-view.js";

const v = await ZsliceView.create(canvas, { wasm: "./zslice/zslice.wasm" });
const info = await v.loadGcode(await fetch("/plate.gcode"), { bedX: 280, bedY: 280 });
slider.max = info.layers;
slider.oninput = () => v.setLayer(slider.value - 1);
```

The canvas gets its size from your CSS. The viewer sets the pixel size of the drawing to the size of the canvas on the page, and follows each change.

## The calls

`ZsliceView.create(canvas, opts)` makes a viewer. The options:

- `wasm`: the URL of `zslice.wasm`. The default is the file next to `zslice-view.js`.
- `module`: a compiled `WebAssembly.Module`, in place of the URL. Use it for many viewers on one page.
- `dark`: `true`, `false`, or `"auto"` (the dark mode of the system). The default is `"auto"`.
- `byFeature`: a color for each feature. The default is `true`.
- `color`: the filament color, `0xRRGGBB`, when `byFeature` is `false`.

`v.loadGcode(source, opts)` reads a file and shows it. It returns `v.info()`.

- `source`: a `Uint8Array`, an `ArrayBuffer`, a `Blob` (a dropped file), a `Response` (of `fetch`), or a `ReadableStream`. A `Response` or a stream goes to the reader as it downloads. The page never holds the whole text.
- `opts.bedX`, `opts.bedY`: the bed size in mm. With no size, the bed goes around the part.
- `opts.onProgress(bytes)`: the bytes read so far.
- `opts.signal`: an `AbortSignal` that stops the read.

The reader gets the file in pieces of 1 MB. After about 30 ms of work, it waits for the next task of the page, so the page can draw and take input. A second `loadGcode` stops the first one. The first one then fails with an `AbortError`.

`v.info()` gives the facts of the file:

| Field | What it is |
|---|---|
| `layers` | The count of layers |
| `layerHeights`, `layerZ` | The height and the top z of each layer (mm) |
| `seconds` | The print time: from the comments of the slicer, else an estimate |
| `meters` | The filament length: from a comment, else the sum of the E of the beads |
| `grams` | The filament weight: from a comment, else an estimate for PLA (1.24 g/cm³) |
| `gramsEstimated` | `true` when the file gives no weight |
| `slicer` | The slicer and its version, for example `Cura_SteamEngine 5.13.0`, or `""` |
| `settings` | Each `key = value` or `key: value` comment of the start and the end of the file, as an object. For CuraEngine: the header (`Layer height`, `MINX`, `FLAVOR`). For zslice: the settings at the end (`project.layer_height`). For PrusaSlicer and Bambu Studio: the config block. |
| `filamentDiameter` | The filament diameter (mm) |
| `box` | The box of the beads: min x, y, z, then max x, y, z (mm) |
| `size`, `moves`, `beads` | The bytes of the file, its moves, and its moves with plastic |

`v.layer(n)` gives layer `n` (from 0): `z`, `height`, `startSeconds`, `endSeconds`, and its bytes in the file (`start`, `end`).

`v.setLayer(n)` shows the layers 0 to `n` (from 0). The top layer is lit, and the layers under it are darker.

`v.setLayerRange(lo, hi)` shows the layers `lo` to `hi`. The layers under `lo` do not show, so the inside of the part at `lo` is visible.

`v.setPosition(offset)` shows the print at a byte offset of the file: the moves before it. Use it with the file position of a printer.

`v.setColors({ byFeature, color })` and `v.setDark(mode)` change the look.

`v.reset()` moves the camera back to the start view.

`v.resize()` sets the size of the drawing to the size of the canvas. A `ResizeObserver` calls it. Call it after a change that the observer does not see.

`v.destroy()` frees the wasm memory and the GPU data, and removes the listeners. The canvas stays on the page.

## The mouse, the touchpad, and touch

The input is the input of the zslice app (`web/app/input.js`):

- A left drag orbits. A right drag of a mouse orbits too.
- A middle drag, or Shift and a drag, pans.
- On a touchpad, two fingers clicked down and slid pan.
- The wheel, a two-finger swipe on a touchpad, and a pinch zoom toward the pointer.
- On a touch screen, one finger orbits. Two fingers pinch to zoom and move to pan.
- A double click moves the camera back to the start view.

## Large files

The reader keeps 24 bytes for each move. The view puts 32 bytes for each bead in one GPU buffer, once. A new layer only changes how many beads draw.

A CuraEngine file of 25 MB with 757 000 beads loaded in 0.4 s in Chromium on a desktop PC. The wasm memory grew to 97 MB. The longest wait between two frames of the page during the load was 0.12 s.

The files to download: `zslice.wasm` is 5.8 MB (1.7 MB with gzip). The five `.js` files are 120 kB together. Turn on gzip or Brotli for `.wasm` on your server.

## Test

```sh
zig build web-view
node web/view/test-view.mjs zig-out/web/view [file.gcode ...]
```

The test reads a CuraEngine file and a zslice file in pieces, checks the facts, and draws frames of the view.
