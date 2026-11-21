# Web, Linux, and Mac

The three apps have the same window and the same tools. The pictures of this guide show the web app.

![The web app on a phone: the header, the Benchy, and the print card](../img/phone.webp "The web app on a phone: one finger orbits, two fingers zoom.")

## The web app

[zslice.beetlebug.org](https://zslice.beetlebug.org/) runs the zslice core in WebAssembly. It needs WebGL2: Chrome, Firefox, or Safari of 2023 or later.

- **Your files stay in your browser.** The model slices on your computer. No file goes to a server. The page has no analytics and no cookies. See [Privacy](../../PRIVACY.md).
- **Your work stays after a reload.** The browser keeps the plates, your settings, and your printers.
- **Open a model from a link.** Add `?model=` and the address of an STL file to the page address.
- **Printers.** The web app cannot search the network. Enter the address of the printer. The printer must allow requests from the page, for example a printdeck at its secure address.
- **On a phone**, the window fits the screen. One finger orbits, and two fingers pinch to zoom and pan.

## The Linux app

A GTK 4 app. Build it from the source tree:

```sh
cd linux
meson setup build        # builds the core too (zig build lib)
ninja -C build
build/zslice-gtk part.stl
```

See [linux/README.md](../../linux/README.md) for the packages. Where it differs from the web app:

- Alt+Left and the back button of the mouse go back to where you were before.
- It shows the active plate only.
- Preferences (Ctrl+,) has the printers, **Test the connection**, and **Get a key**. The API keys are in `~/.config/zslice/app.ini`.
- It has layer profiles, **Compare with Cura…**, USB printers, **Send all plates**, and **Export all plates…**.
- The part card of a painted part shows the filaments of its paint, with a button that opens the Paint tool.

## The macOS app

A SwiftUI app with a Metal view. See [The macOS app](macos.md): its keys, its settings pane, Bambu printers, the Keychain, and the farm queue.

## The command line

To slice with no window, see [The command line](command-line.md).
