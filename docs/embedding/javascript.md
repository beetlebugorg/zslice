# JavaScript and WebAssembly

## The npm package

The package `@beetlebugorg/zslice` is on GitHub Packages (not npmjs.com). It has the web app (`app/`), this API (`zslice.mjs`), and a Node command, `zslice slice`, that slices a model to G-code with profiles. Each version tag publishes it (`.github/workflows/npm.yml`). See [its README](https://github.com/beetlebugorg/zslice/blob/main/web/npm/README.md) for the install: GitHub Packages needs a token, also to install.

```sh
npm install @beetlebugorg/zslice
npx zslice slice part.stl -m printer.toml -p fine -o part.gcode
```

To serve the web app from your own server (for example a printer on the LAN), serve `node_modules/@beetlebugorg/zslice/app/`. It uses only relative URLs. Send `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` for the threads.

To build the package from the source: `zig build web && python3 -I tools/npm_package.py`, then `zig-out/npm`.

## Build

```sh
zig build wasm
```

This makes `zig-out/web/zslice.wasm` (about 1.2 MB) and `zig-out/web/zslice.mjs` (the wrapper).

The module has one import, `env.zs_web_event`: the events of the app core (see [The app core in a browser](#the-app-core-in-a-browser)). `zslice.mjs` gives an empty function for it. If you instantiate the module yourself, give one too:

```js
const { instance } = await WebAssembly.instantiate(wasmBytes, { env: { zs_web_event() {} } });
```

## Use

```js
import { load, ZsliceError } from "./zslice.mjs";

const wasmBytes = await (await fetch("zslice.wasm")).arrayBuffer();
const zslice = await load(wasmBytes);

const stlBytes = new Uint8Array(await file.arrayBuffer());
try {
  const { gcode, stats } = zslice.sliceStl(stlBytes, {
    "project.layer_height": 0.15,
    "project.wall_count": 3,
    "filament.nozzle_temp": 220,
  });
  console.log(`${stats.layerCount} layers, ${(stats.filamentMm / 1000).toFixed(2)} m`);
} catch (e) {
  if (e instanceof ZsliceError) console.error(e.message, e.status);
  else throw e;
}
```

## The wrapper API

`load(wasmBytes)` returns an object with:

| Member | What it is |
|---|---|
| `version` | The version text. |
| `settingNames` | An array of all setting names. |
| `sliceStl(stlBytes, settings)` | Slices an STL file. `stlBytes` is a `Uint8Array` or an `ArrayBuffer`. `settings` is an object of `"group.name": value`. Returns `{ gcode, stats }`. |

`stats` has `layerCount`, `retractions`, `filamentMm`, `filamentG`, `printTimeS`, and `travelMm`.

On a failure, `sliceStl` throws a `ZsliceError`. Its `status` field is the C status code (see the [overview](overview.md#errors)).

## Run it in a Web Worker

The wasm module has no threads, and a slice blocks the thread that runs it. In a browser, run it in a Web Worker:

```js
// worker.mjs
import { load } from "./zslice.mjs";
const zslice = await load(await (await fetch("zslice.wasm")).arrayBuffer());
self.onmessage = (e) => {
  try {
    self.postMessage(zslice.sliceStl(e.data.stl, e.data.settings));
  } catch (err) {
    self.postMessage({ error: err.message, status: err.status });
  }
};
```

```js
// page.js
const worker = new Worker("worker.mjs", { type: "module" });
worker.onmessage = (e) => console.log(e.data);
worker.postMessage({ stl: stlBytes, settings: { "project.wall_count": 3 } }, [stlBytes.buffer]);
```

## Node.js

`web/test.mjs` is a working example for Node.js:

```sh
node web/test.mjs zig-out/web/zslice.wasm part.stl
```

## The app core in a browser

The module also exports the app core and the 3D view of `include/zslice-app.h`. The web app (`web/app/`, see its [README](../../web/app/README.md)) uses them:

- `zs_app_new_web` makes an app whose events go to the import `env.zs_web_event(event, progress, status)`. A slice runs on the calling thread, so run the app in a Web Worker.
- `zs_view_new` with `ZS_SURFACE_WEB` (3) makes a 3D view with no GPU in the core. After `zs_view_draw`, `zs_view_web_frame` gives the frame data in wasm memory, and the page draws it with WebGL2 (see `web/app/gl.js`).
- `zs_view_scene_write` and `zs_view_scene_read` move the loaded scene from the view of one wasm instance (the worker) to the view of another (the main thread).

## Memory

The wasm memory grows while a slice runs, and it does not shrink. To free all memory, drop the module object and load it again.
