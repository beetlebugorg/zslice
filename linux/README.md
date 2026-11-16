# zslice for Linux (GTK4)

A native GTK4 app around the zslice app core. See `docs/app/README.md` for the split between the core and the shell.

## Requirements

- GTK 4.14 or later, with its development files.
- Zig 0.16 on the `PATH`.
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

## Use

- Open a model with the Open button, Ctrl+O, or drag and drop an STL file on the window.
- Change a setting: press Enter, or move to another field. The app slices again at once.
- Pick a layer with the slider on the right, or with the arrow keys.
- Scroll to zoom, drag to pan, and double-click to fit the part.
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
