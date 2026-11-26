# zslice for Linux (GTK4)

A native GTK4 app around the zslice app core. See `docs/app/README.md` for the split between the core and the shell.

## Requirements

- GTK 4.14 or later, with its development files.
- Zig 0.17 on the `PATH`.
- meson and ninja.

```sh
sudo pacman -S gtk4 meson ninja             # Arch
sudo apt install libgtk-4-dev meson ninja-build   # Debian, Ubuntu
```

## Build and run

```sh
meson setup build
ninja -C build
./build/zslice-gtk [part.stl]
```

meson runs `build-core.sh`, which runs `zig build lib` and puts `libzslice.a`, `zslice.h`, and `zslice-app.h` in the build folder. The core is `ReleaseFast` by default. Use `meson configure build -Dcore-optimize=Debug` to debug the core.

`meson test -C build` runs the tests of the network code (`tests/`). They use servers on 127.0.0.1 only: a redirect to another host gets no API key, and a Bambu Lab printer with another certificate gets no access code. The second test needs `openssl` to make its certificates, and is skipped without it.

## Use

- Open a model with the Open button, Ctrl+O, or drag and drop an STL file on the window.
- Change a setting: press Enter, or move to another field. The app slices again at once.
- Pick a layer with the slider on the right, or with the arrow keys.
- In the 2D view: scroll to zoom, drag to pan, and double-click to fit the part.
- In the 3D view: left drag to orbit (turn and tilt), middle drag to pan, right drag to rotate freely in any direction, scroll to zoom toward the pointer, and double-click to reset the view. A left click picks a line.
- Export the G-code with the Export G-code button or Ctrl+E.

## Files

| File | What it does |
|---|---|
| `src/main.c` | The GtkApplication, the actions, and the shortcuts. |
| `src/model/app-model.c` | `ZgModel`: owns the core, and moves core events to the main thread. |
| `src/ui/window.c` | The main window: header bar, panels, status bar, open, export, drop. |
| `src/ui/settings-panel.c` | The settings panel, built from the setting descriptions of the core. |
| `src/ui/preview.c` | The layer preview (cairo) and the layer slider. |
| `src/ui/licenses.c` | The Licenses window. |
