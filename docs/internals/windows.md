# The Windows app

The Windows app is planned: a native shell over the Zig core, in `windows/`. The plan is a WinUI 3 shell in C++/WinRT, and a Direct3D 12 backend in the core. Only the core is shared with the other apps.

The port is in progress. Today `windows/` has the build scripts of the core and a link test. The shell and the Direct3D backend do not exist yet. This page describes the parts that exist.

## Build the core

The core needs Zig 0.16 and Visual Studio with the C++ tools.

```powershell
pwsh windows/build-core.ps1 -Platform x64
pwsh windows/build-tests.ps1 -Platform x64
```

- **`build-core.ps1`** runs `zig build lib` for the MSVC target of the platform. The result is `zig-out/lib/zslice.lib`, with the headers in `zig-out/include`.
  - A Release core is ReleaseFast.
  - The script sets `-Dcompiler-rt`, so the library has the f128 helpers that `std.json` and `std.fmt.parseFloat` call.
  - For an ARM64 core on an x64 machine, the script gives Zig a libc file with the ARM64 library folders.
- **`build-tests.ps1`** compiles `windows/test/core_link.c` with MSVC, links the core, and runs the program. The test opens a G-code file by a UTF-8 path with characters outside the ANSI code page.

To link an ARM64 program, Visual Studio needs the component "MSVC ARM64 build tools". The core itself compiles without it.

## What differs from the other platforms

- `zig build lib` installs only the static library on Windows. The import library of a DLL has the same name, `zslice.lib`.
- Each path in the C API is UTF-8. `zs_gcode_open` converts the path to UTF-16 and calls `_wfopen`.
- `zslice bench` reads the CPU time with `GetProcessTimes`, and the page faults and the peak memory with `K32GetProcessMemoryInfo`.
