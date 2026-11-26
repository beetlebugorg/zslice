# Zig 0.17

zslice builds with Zig 0.17.0. This page lists the changes of the move from Zig 0.16.0 and the checks of the move.

## Changes

- `build.zig.zon` has `.minimum_zig_version = "0.17.0"`. Each CI workflow sets Zig 0.17.0. The Homebrew formulas depend on `zig`, and the Xcode script phase looks for a Zig 0.17 in `ZIG`, on the path, and in Homebrew.
- `@cImport` is gone. `src/render/vulkan_c.h` has the Vulkan include, and the build translates it with `b.addTranslateC` into the module `vulkan_c` of the C library. `src/render/vk.zig` imports that module.
- `@typeInfo` of a struct has the arrays `field_names` and `field_types`, and an enum has `field_names` and `field_values`. `src/type_fields.zig` zips these arrays into one record for each field, so the loops over the settings read `f.name` and `f.type` as before.
- The array repeat operator `**` is gone. A run of one value is `@splat`. The repeated strings of the G-code header and of the tests are plain literals.
- The optimize modes are lower case: `.debug`, `.safe`, `.fast`, `.small`. `-Doptimize=ReleaseFast` still works on the command line.
- `std.ascii.indexOfIgnoreCase` is `std.ascii.findIgnoreCase`. `std.meta.Int` is `@Int`. `Allocator.dupeZ` is `dupeSentinel(u8, s, 0)`. `StaticBitSet.initEmpty()` is `.empty`.
- `std.ArrayList` has the field `pointer_stability`. A list made from its parts sets `.pointer_stability = .{}`.

## Checks

These checks ran on 2026-11-26 on an x86_64 Linux machine with 8 cores. They compare the branch with main 70dd0b3c built by Zig 0.16.0.

- `zig build test`, `zig build verify`, `zig build lib`, and `zig build web` pass. `zig build lib` builds for `x86_64-windows-msvc` and `aarch64-macos`.
- `tools/corpus_hash.py` gives the same G-code hash for each of the 4 files of the test parts (3DBenchy, the bunny, the M3x10 screw, and the KSR test) and for each of the 109 STL files of the Printdeck corpus. All 113 slices have the status `ok`.
- `zslice bench 3DBenchy.stl`, interleaved runs of each build: in 3 runs, the CPU median of the full slice is 1,415 to 1,427 ms with 0.17.0 and 1,462 to 1,471 ms with 0.16.0. In 7 runs, the least wall time is 238 ms with 0.17.0 and 249 ms with 0.16.0. Other jobs used the machine, so the wall times of single runs vary by up to 50 percent.
