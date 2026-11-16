# JavaScript and WebAssembly

## Build

```sh
zig build wasm
```

This makes `zig-out/web/zslice.wasm` (about 120 KB) and `zig-out/web/zslice.mjs` (the wrapper).

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

## Memory

The wasm memory grows while a slice runs, and it does not shrink. To free all memory, drop the module object and load it again.
