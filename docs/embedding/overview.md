# Embedding zslice: overview

zslice is a library first. The command line tool is a small program on top of it. You can use the library from Zig, from C (or any language with a C foreign function interface), and from JavaScript through WebAssembly.

## The objects

| Object | What it is |
|---|---|
| Mesh | The triangles of the part, with welded vertices. Load it from STL bytes, or make it from a triangle list. |
| Settings | All settings, in four groups: `machine`, `filament`, `project`, `engine`. Each has a default. Change a setting by its name and a text value. |
| Stats | The result of a slice: the layer count, the filament length and weight, the time estimate, the travel distance, and the retraction count. |
| Job (Zig only) | A slice after its first pass. It has the outline of each layer. Use it to get the paths of one layer (for a preview) without the G-code. |

## The flow

1. Load the mesh.
2. Make the settings and change the ones you need.
3. Slice. The G-code goes to your writer (Zig), to your callback (C), or into one buffer.
4. Free the mesh and the settings.

The library does not read or write files. Your program gives it bytes and gets bytes back. Thus the same API works in a browser, on a server, and on a printer controller.

## Setting names

A setting name is `group.name`, for example `project.wall_count`. The value is always text: `"3"`, `"0.2"`, `"true"`, `"grid"`. The library parses it to the type of the setting. To list all names:

- Zig: look at `zslice.Settings` (`src/settings.zig`), or run `zslice settings`.
- C: `zs_setting_names()` returns all names, one on each line.
- JavaScript: `zslice.settingNames`.

The [settings reference](../user/settings.md) has the meaning, unit, and default of each setting.

## Memory

- The library allocates memory only through the allocator that you give it (Zig), or through its own allocator (C and wasm).
- The G-code goes out while the slice runs. The library never holds the whole G-code file, unless you use the buffer API.
- The peak memory is about: the mesh, plus the outline of each layer, plus the paths of one batch of layers. The batch size is 4 layers for each thread (at least 8). With the 109 STL files of the printdeck repo, the largest peak was 95 MB for the whole command line process.

## Threads

- Native builds use one thread for each CPU by default. Set `engine.threads` to change it. `engine.threads=1` uses only the calling thread.
- The output does not depend on the thread count: the G-code is the same bytes with 1 thread and with 8 threads.
- In Zig, the allocator must be thread-safe if `engine.threads` is not 1. `std.heap.smp_allocator` and `std.heap.c_allocator` are thread-safe.
- The wasm build has no threads. In a browser, run the slice in a Web Worker, so that the page does not stop.
- A mesh and a settings object can be used by more than one slice at the same time. The slice does not change them.

## Errors

Each failure has a name. In Zig, it is an error value. In C, it is a status code. In JavaScript, it is a `ZsliceError` with a `status` field.

| Zig error | C status | Meaning |
|---|---|---|
| `error.OutOfMemory` | `ZS_OUT_OF_MEMORY` (1) | The allocator has no more memory. |
| | `ZS_INVALID_ARGUMENT` (2) | A required pointer is NULL (C only). |
| `error.InvalidStl` | `ZS_INVALID_MESH` (3) | The bytes are not a valid STL file. |
| `error.EmptyMesh` | `ZS_EMPTY_MESH` (4) | No triangles, or no height. |
| `error.UnknownSetting` | `ZS_UNKNOWN_SETTING` (5) | The setting name does not exist. |
| `error.InvalidValue` | `ZS_INVALID_VALUE` (6) | The value text cannot be parsed to the setting type. |
| `error.InvalidSettings` | `ZS_INVALID_SETTINGS` (7) | The values together cannot make a print. |
| `error.PartTooLarge` | `ZS_PART_TOO_LARGE` (8) | The part is higher than `machine.max_height`. |
| `error.WriteFailed` | `ZS_WRITE_FAILED` (9) | The writer failed, or the C callback returned a value that is not 0. |

## Stability

zslice is at version 0.1. The API can change before version 1.0. Setting names can also change. The change log will list each change.

## The language guides

- [Zig](zig.md)
- [C](c.md)
- [JavaScript and WebAssembly](javascript.md)

The app core has guides of its own: [the print view](print-view.md) and [labels on a part](labels.md).
