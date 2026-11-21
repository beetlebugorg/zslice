# The Windows app

The Windows app is planned: a native shell over the Zig core, in `windows/`. The plan is a WinUI 3 shell in C++/WinRT, and a Direct3D 12 backend in the core. Only the core is shared with the other apps.

The port is in progress. Today `windows/` has the build scripts of the core and a link test. The shell and the Direct3D backend do not exist yet. This page describes the parts that exist.

## Build the app

The app is unpackaged and self-contained: the build copies the Windows App SDK next to the program. Build the core first, then the shell, for each platform:

```powershell
pwsh windows/build-core.ps1 -Platform x64
cd windows
msbuild ZSlice.vcxproj -t:Restore -p:Configuration=Release -p:Platform=x64
msbuild ZSlice.vcxproj -p:Configuration=Release -p:Platform=x64
.\x64\Release\ZSlice.exe part.stl
```

Use `-Platform ARM64` and `-p:Platform=ARM64` for ARM64. The project needs the toolset v145 (Visual Studio 2026 or its Build Tools). `ZSLICE_LOG=path` writes the log lines of the shell and the core to a file.

## The shell

| File | What it has |
|---|---|
| `src/model/zs_model` | The core as one object: the plate set, the file reads, and the core events. It has no WinRT. |
| `src/app/MainWindow` | The window: the view in a `SwapChainPanel`, the open flow, the layer slider, the status bar, and the pointer input. |
| `src/app/App` | The start of the app, and `ZSLICE_LOG`. |
| `src/app/winrt_glue.cpp` | Compiles the generated XAML files, which a command-line build does not register. |

- The core events come on the slice threads. The model posts each one to the UI thread through the `DispatcherQueue`.
- The view draws only after a change. `ZS_BUSY` means that the compositor holds the frame before, and a timer draws again 8 ms later.
- The swapchain is in device pixels. The shell sets the inverse of the composition scale on it with `SetMatrixTransform`.
- A left drag orbits. A right drag orbits with a mouse and pans with a two-finger click on a touchpad. The middle button and Shift pan. The wheel and a pinch zoom.

## Build the core

The core needs Zig 0.16 and Visual Studio with the C++ tools. The app builds for x64 and ARM64.

```powershell
pwsh windows/build-core.ps1 -Platform x64
pwsh windows/build-tests.ps1 -Platform x64
pwsh windows/build-core.ps1 -Platform ARM64
pwsh windows/build-tests.ps1 -Platform ARM64
```

- **`build-core.ps1`** runs `zig build lib` for the MSVC target of the platform. The result is `lib/zslice.lib` and `include/` under `zig-out/windows-x64` or `zig-out/windows-arm64`, so both platforms stay built.
  - A Release core is ReleaseFast.
  - The script sets `-Dcompiler-rt`, so the library has the f128 helpers that `std.json` and `std.fmt.parseFloat` call.
  - For an ARM64 core on an x64 machine, the script gives Zig a libc file with the ARM64 library folders.
- **`build-tests.ps1`** compiles the programs in `windows/test` with MSVC, links the core, and runs them.
  - `core_link.c` opens a G-code file by a UTF-8 path with characters outside the ANSI code page.
  - `view_offscreen.c` draws a model with Direct3D 12, reads the frame, and checks its pixels, also after a resize. Set `ZSLICE_WARP=1` to run it on the software rasterizer.

To link an ARM64 program, Visual Studio needs the component "MSVC ARM64 build tools" (`Microsoft.VisualStudio.Component.VC.Tools.ARM64`). The core itself compiles without it. An x64 machine builds the ARM64 test programs and does not run them.

## The Direct3D 12 backend

`src/render/d3d12.zig` has the interface of `src/render/vk.zig`, so `src/render/view.zig` is the same on each platform. The HLSL files in `src/render/shaders/d3d12` are the forms of the GLSL shaders. A change to a GLSL shader needs the same change there.

- A view on `ZS_SURFACE_PANEL` makes a composition swapchain. The shell gets it with `zs_view_swapchain` and gives it to `ISwapChainPanelNative::SetSwapChain`.
- The swapchain has a frame latency of 1 and a waitable object. A frame that the compositor cannot take returns `ZS_BUSY`, so a present does not block the UI thread.
- The view builds its matrices for a clip space with y down. The vertex shaders negate y.
- `SV_InstanceID` starts at 0 for each draw. A root constant gives the shader the first instance of the draw, for the highlight.
- The backend writes its log lines to stderr itself. `std.log` does not compile for ARM64 Windows in Zig 0.16.
- A print view offscreen draws all its layers each frame. It has no cached image of the finished layers.

## What differs from the other platforms

- `zig build lib` installs only the static library on Windows. The import library of a DLL has the same name, `zslice.lib`.
- Each path in the C API is UTF-8. `zs_gcode_open` converts the path to UTF-16 and calls `_wfopen`.
- `zslice bench` reads the CPU time with `GetProcessTimes`, and the page faults and the peak memory with `K32GetProcessMemoryInfo`.
