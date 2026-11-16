# zslice

A slicer for FDM 3D printers, written from scratch in Zig.

Goals: a clean API for embedding (Zig, C, and WebAssembly), high performance, low memory use, advanced slicing features, and code that teaches how a slicer works. See `ROADMAP.md` for the status.

## Documentation

- For people who slice: [Getting started](docs/user/getting-started.md), [Settings reference](docs/user/settings.md).
- For developers who use the library: [Embedding overview](docs/embedding/overview.md), with guides for Zig, C, and JavaScript.
- For developers who extend zslice: [How a slicer works](docs/internals/how-slicing-works.md), [Architecture](docs/internals/architecture.md), [Contributing](docs/internals/contributing.md).

All documents: [docs/README.md](docs/README.md).

## Build

zslice needs Zig 0.16.

```sh
zig build test                      # run the tests
zig build -Doptimize=ReleaseFast    # the command line tool: zig-out/bin/zslice
zig build lib -Doptimize=ReleaseFast  # libzslice.a, libzslice.so, zslice.h
zig build wasm                      # zig-out/web/zslice.wasm and zslice.mjs
```

## Command line

```sh
zslice slice part.stl -o part.gcode -s project.wall_count=3 -s filament.nozzle_temp=220
zslice preview part.stl --layer 20 -o layer20.svg
zslice settings                     # all settings and their defaults
zslice demo demo.stl                # write a test part
```

## Settings

The settings have three groups, with different owners:

- `machine.*`: facts about the printer. Examples: the bed size, the nozzle, and the speed limits.
- `filament.*`: facts about the material. Examples: the temperatures, and the maximum flow that the hot end can melt.
- `project.*`: what you want for this part. Examples: the layer height, the walls, and the infill.

A project does not set speeds in mm/s. It sets a ratio of the speed that the machine and the filament allow. One project then works on different printers and with different filaments.

## Embedding

Zig:

```zig
const zslice = @import("zslice");

var mesh = try zslice.Mesh.fromStl(gpa, stl_bytes);
defer mesh.deinit(gpa);
var settings: zslice.Settings = .{};
try settings.set("project.wall_count", "3");
const stats = try zslice.slice(gpa, &mesh, settings, writer);
```

C (`include/zslice.h`):

```c
zs_mesh *mesh;
zs_mesh_load_stl(bytes, len, &mesh);
zs_settings *settings;
zs_settings_new(&settings);
zs_settings_set(settings, "project.wall_count", "3");
zs_slice(mesh, settings, write_callback, user_data, &stats);
```

JavaScript (`web/zslice.mjs`):

```js
import { load } from "./zslice.mjs";
const zslice = await load(wasmBytes);
const { gcode, stats } = zslice.sliceStl(stlBytes, { "project.wall_count": 3 });
```

## License

AGPL-3.0-or-later. See `LICENSE`. The sources that zslice uses, and the licenses of the code in its binaries, are in `REFERENCES.md`.
