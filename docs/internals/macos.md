# The macOS app

The macOS app is a native shell over the Zig core. It is in `macos/`. It uses SwiftUI, AppKit where SwiftUI falls short, and Metal for the 3D view. Only the core is shared with the other apps. The app follows the layout plan in [One view](one-view.md), in the way a Mac app does it.

## Build

The app needs Zig 0.16 and the Swift 6 tools of Xcode (macOS 14 or later).

```sh
cd macos
ZIG=/path/to/zig-0.16/zig ./build-core.sh   # lib/libzslice.a, for arm64 and x86_64
./make-app.sh                                # build/zslice.app
open build/zslice.app
```

`build-core.sh` runs `zig build lib` for `aarch64-macos` and `x86_64-macos`, and merges the two static libraries with `lipo`. `make-app.sh` builds the Swift package (`swift build`), and makes the app bundle with `Info.plist` and an ad-hoc signature. The project is a Swift package, not an Xcode project, so the build files are plain text.

## The parts

| File | What it does |
|---|---|
| `Package.swift` | The package: the C module and the app target. |
| `Sources/CZslice/module.modulemap` | The C API of the core (`include/zslice-app.h`) as the Swift module `CZslice`. |
| `Sources/ZSlice/ZSliceApp.swift` | The app and its document type. Each window is one STL or 3MF file. |
| `Sources/ZSlice/Core/SliceModel.swift` | One plate: one `zs_app` of the core, its state, and its events. |
| `Sources/ZSlice/Core/Workspace.swift` | The model of a window: the plate, the 3D view, the layer range, the replay, and the keys of the view. |
| `Sources/ZSlice/Views/MetalSliceView.swift` | The 3D view: an `NSView` over a `CAMetalLayer`, its display link, and the input. |
| `Sources/ZSlice/Render/FrameRenderer.swift` | Draws the frame data of the core with Metal. |
| `Sources/ZSlice/Render/LayerRenderer.swift` | Draws the 2D view of one layer with Metal: the bed, the outline (a stencil fill), and the beads as strokes. |
| `Sources/ZSlice/Render/Shaders.swift` | The Metal shaders. They port `src/render/shaders/*`, and the 2D shaders of `web/app/gl.js`. |
| `Sources/ZSlice/Views/DocumentWindow.swift` | The window: the 3D view, the scrub bar, and the print card. |
| `Sources/ZSlice/Views/LayerSlider.swift` | The slider with two knobs for the layers that show. |

## Threads

The core slices on its own threads, and calls the event function there. The event function only posts the event to the main queue (`DispatchQueue.main.async`). All calls into the core run on the main thread. A change calls `zs_app_request_slice`, which stops a slice that runs and starts a new one, so the main thread never waits for a slice.

## The 3D view

On macOS the core does not draw. The view is a `zs_view` with no surface (`ZS_SURFACE_FRAME`). The core uses its frame backend (`src/render/web.zig`), the same as the web app. After each `zs_view_draw`, the view keeps the frame data (`zs_view_web_frame`): the bead instances, the bead mesh and its levels of detail, the draw list, the grid, the bed model, the other plates, and the push constants. `FrameRenderer` reads that data and makes the draw calls of the Vulkan backend, as `web/app/gl.js` does with WebGL2.

- The camera, the pick, the culling, and the levels of detail stay in the core.
- A buffer goes to the GPU again only when its generation changes. Each upload makes a new `MTLBuffer`, so a frame in flight keeps its old buffer.
- The core makes its matrices for the clip space of Vulkan (y down, depth 0 to 1). Each Metal vertex shader turns y over.
- The drawable format is UNORM: the shaders work in sRGB values, as in the Vulkan backend. The view draws with 4x multisampling.
- The app compiles the shader source when it starts, so the build needs no Metal tools.
- The view draws only after a change. Its display link (`NSView.displayLink`, macOS 14) runs while a frame waits or the camera moves, and pauses after that.
- The view passes pixels to the core: points times the backing scale, with the origin at the top left (the view is flipped).
- The dark look of the view follows the appearance of the window (`zs_view_set_dark`).

### The 2D page

The 2D page shows one layer from the top: the top layer of the layer slider. It uses the same bead buffer on the GPU as the 3D page, so a new layer only changes the range of a draw. The outlines of all layers (`zs_view_outlines`) go to the GPU once for each slice, as fans of triangles. The stencil buffer fills them by the nonzero rule. The toolbar of the window switches the page, and so do View > 3D View (Command-1) and View > 2D Layer View (Command-2). The app keeps the choice for the next window. On the 2D page, a drag pans, the wheel and a pinch zoom toward the pointer, and a double click fits the part (View > Fit the Part, Command-0).

### Input

The bindings are those of the GTK app, with the keys of a Mac:

- A left drag orbits.
- A right or middle drag pans. A two-finger press and drag on a trackpad is a right drag, so it pans too.
- A two-finger scroll on a trackpad zooms toward the pointer. So do the mouse wheel and a pinch.
- A right click with no drag opens the context menu, and so does Control-click.
- Command-click, Command-drag, and Command-scroll select, move, and turn a part (Ctrl on Linux).

## Native parts

The app uses the system parts of macOS where it can:

- SwiftUI document windows: the open panel, Open Recent, window tabs, and full screen.
- The menus of a Mac app, with Command keys, and Settings in the app menu.
- Materials (vibrancy), system fonts, and the accent color for the cards.
- The Keychain for the API keys of printers.
- `UndoManager`, wired to the history of the core.

## Development hooks

Like the GTK shell, the app reads some environment variables for development and screenshots:

- `ZSLICE_SNAPSHOT=path.png` writes the window to that PNG file, a moment after the first frame of a slice. The 3D view comes from Metal and the controls from AppKit (`cacheDisplay`), so it needs no permission to record the screen.
- `ZSLICE_LAYERS=lo,hi` sets the layer range after the first slice (layer numbers from 1).
- `ZSLICE_TIME=t` shows the replay at t seconds after the first slice.
- `ZSLICE_VIEW=2d` (or `3d`) opens the window on that page.

## Work that moves to the core

App logic goes in the core, so that the three shells do not each have a copy. Two parts of the app move there:

- The history of undo and redo (the steps, the amend rule of an edit, the memory cap, and the restore). Today `linux/src/model/app-model.c` and `web/app/worker.js` each have it. The Mac app maps the core history onto `UndoManager`.
- The plate set: one `zs_app` for each plate, the order of the slices (the active plate first), and the sync of the plates of the 3D view. Until it lands, a Mac window has one plate.

## Status and plan

The work goes in steps. Each step keeps `zig build test`, `zig build web`, and the GTK build working.

1. The core link and the 3D view: open a file, slice, and show the beads with Metal. Done.
2. The slicing UI: the print card and Export G-code, the layer slider, the replay, and the 2D layer view (done); the settings drawer, and history and undo (after the core history).
3. The tools (Select, Move, Turn, Measure, Gaps, Check), the line and part cards, the settings search, the shortcut sheet, and a double click that faces a side.
4. Printers (the picker, the library, App Keys, printdeck, OctoPrint, Moonraker, discovery) and printdeck.yml projects. The menus, drag and drop, and the user docs.
