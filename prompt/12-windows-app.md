# 12. The Windows app (WinUI 3 and Direct3D 12)

## Goal

Build the native Windows app in `windows/`: a WinUI 3 shell in C++/WinRT around the app core, with a Direct3D 12 backend in the core. It builds for x64 and ARM64. The port is in progress at the commit this folder describes. Build the parts in the order below, and match the web app for each part that exists.

## Read first

- [The Windows app internals](../docs/internals/windows.md): the build, the shell files, the printers, the core build, the Direct3D 12 backend, and the differences from the other platforms. Its first paragraph is older than its file table. The file table lists the session, the menu, the printers, the picker, the farm, and the send.
- [The Windows app user guide](../docs/user/windows.md).
- Part 08 (the view) and part 09 (the layout, the cards, and the keys).

## Build

1. `windows/build-core.ps1 -Platform x64` (and `ARM64`): `zig build lib` for the MSVC target, ReleaseFast, with `-Dcompiler-rt`. The results stay apart under `zig-out/windows-x64` and `zig-out/windows-arm64`. An ARM64 core on an x64 machine gets a libc file with the ARM64 library folders.
2. `windows/build-tests.ps1`: `core_link.c` (a UTF-8 path outside the ANSI code page), `view_offscreen.c` (draws with Direct3D 12 and checks the pixels; `ZSLICE_WARP=1` for the software rasterizer), and `net_link.cpp` (links against stub servers on 127.0.0.1).
3. `msbuild ZSlice.vcxproj -t:Restore`, then `msbuild ZSlice.vcxproj`, as two calls. The app is unpackaged and self-contained.
4. `src/render/d3d12.zig` with the interface of `vk.zig`, and HLSL forms of each GLSL shader in `src/render/shaders/d3d12`. A change to a GLSL shader needs the same change there. Declare the COM vtables in `src/render/c_d3d12.zig`, so the build needs no Windows SDK header.
5. A composition swapchain on `ZS_SURFACE_PANEL` for a `SwapChainPanel` (`zs_view_swapchain`). Frame latency 1 and a waitable object. A frame that the compositor cannot take returns `ZS_BUSY`; draw again 8 ms later.
6. The shell files in the table of the internals page: the model (no WinRT), the plate bar and signs (GDI+), the settings pane, the tools, the cards, the filaments, Paint, Label, Support, the session, the menu, the context menu, the 2D view (Direct2D on its own swapchain), the chrome, the color tokens of `web/app/style.css`, the printers, the picker, the farm, and the send.
7. `src/prefs/`: secrets with DPAPI (`CryptProtectData`). `app.ini` has no secret.
8. `src/net/`: WinHTTP, Schannel, the printer links, the search, Bambu Lab, and the cameras.

## Rules that matter

- Each path in the C API is UTF-8. `zs_gcode_open` converts to UTF-16 and calls `_wfopen`.
- The session is `session.zslice` in `%APPDATA%\zslice`. Write no session until the restore at launch is done. A session that does not read moves to `session.zslice.bad`.
- Mouse: a left drag orbits. A right drag orbits with a mouse, and pans with a two-finger click on a touchpad. The middle button and Shift pan. The wheel and a pinch zoom.
- A Label edit goes to the core 400 ms after the last change or at the end of a drag, so it is one history step. A Support drag sends its edit at most each 60 ms and slices at most each 150 ms.
- **No print starts from the Windows app yet.** `zs::link::Upload` always sends `print=false`. The Bambu Lab link sends no PUBLISH.
- A request follows no redirect and uses no proxy, so a key cannot go to another host.
- The view builds its matrices for a clip space with y down; the vertex shaders negate y. `SV_InstanceID` starts at 0 for each draw, so a root constant gives the first instance for the highlight.
- The backend writes its log lines to stderr itself: `std.log` does not compile for ARM64 Windows in Zig 0.16.

## Lessons

- Keep the x64 and ARM64 cores side by side, so both platforms stay built.
- A command-line build does not register the generated XAML files: compile them in `winrt_glue.cpp`.

## Acceptance checks

1. CI builds the core and links the tests for x64 and ARM64, and builds the app with msbuild.
2. `view_offscreen.c` draws a model, and its pixels pass, also after a resize.
3. `net_link.cpp` passes against the stubs, and contacts no real printer.
4. The app opens a model, slices it, draws it, and shows the plates with signs and bed models.
5. A close and a start bring back the session.
