# 10. The Linux app (GTK 4 and Vulkan)

## Goal

Build the native Linux app in `linux/`: a GTK 4 shell in C around the app core, with the 3D view drawn by the Vulkan backend of the core into a Wayland subsurface. It has the window, the tools, the cards, and the keys of the web app, plus the features that need a desktop: network discovery, USB printers, Preferences, and Bambu Lab status and cameras.

## Read first

- [The app](../docs/app/README.md): the GTK file table and the test hooks table (`ZSLICE_*`). Use both as the spec of the shell.
- [linux/README.md](../linux/README.md): the build with meson and ninja. Its mouse list is older than the code. [Keys and mouse](../docs/user/keys.md) is correct.
- [Web, Linux, and Mac](../docs/user/apps.md): where the Linux app differs from the web app.
- Part 09 of this folder: the window layout, the card rules, and the keys are the same.

## Build

1. `meson setup build`, `ninja -C build`. meson runs `build-core.sh`, which runs `zig build lib` (ReleaseFast by default). GTK 4.14 or later.
2. `model/app-model`: the core as a GObject. Events go to the UI thread with `g_idle_add`. A watchdog of the UI thread in `main.c`.
3. `ui/native-surface`: a Wayland subsurface under the window for the Vulkan view. The GTK window is transparent, and the view widget draws no pixel. Each other part of the window paints its whole area (use padding in place of margins).
4. `ui/view3d`, `ui/preview`, `ui/layer-draw` (cairo 2D view), `ui/float` (the cards over the view), `ui/line-card`, `ui/part-card`, `ui/search`, `ui/shortcuts`, `ui/settings-panel` (a drawer: hidden, over the view, or pinned), `ui/history`, `ui/printer-picker`, `ui/farm-page`, `ui/project-page`, and the Paint, Label, and Support tools.
5. `net/printer-link`: HTTP and USB serial links. `net/discovery`: mDNS with the packets of the core. `net/project-source`: a folder or a public GitHub repository.
6. `prefs/printers`: the printers of the user and the app settings in `~/.config/zslice/`. The API keys are in `app.ini` there. A Bambu access code goes in `~/.config/zslice/bambu/<serial>.code`, readable only by the user.
7. Open links: the `.desktop` file has `MimeType=x-scheme-handler/zslice` and the model types. `ui/open-link.c` asks first. `net/model-download.c` downloads with libsoup. It resolves the host, and checks each address and each connection peer. A second start hands the link to the first window, and the session comes back before the file opens.
8. The Label tool draws its handles as decals of the core view, in place of a handle widget over the view. The card has the modes and "Place an SVG…" with a file dialog. An SVG dropped on a part makes a label. Other files go to the window.
9. The Calibrate menu, "Import a profile...", the part order on the part card, the draft slice first, and the work bar, as on the web.
10. Test hooks: each `ZSLICE_*` variable in the table of the app page. Use them to drive the app in tests and screenshots: `ZSLICE_PICK`, `ZSLICE_MENU`, `ZSLICE_RING_DRAG`, `ZSLICE_GRAB`, `ZSLICE_SUPPORT_DO`, `ZSLICE_BENCH`, `ZSLICE_PLATES`, and the others. `ZSLICE_STALLS=ms` logs each stall of the UI thread with stacks. `ZSLICE_STRESS=n` makes n fast changes.

## Rules that match the other apps

- The key sheet in two columns, as on the web. The tool strip glyphs and the history glyphs use the paths of the web glyphs.
- A long label wraps at the ends of words. No label ends in "…".
- Cards keep clear of the clicked line or part, with the rules of `web/app/place.js`.
- A right drag of a mouse orbits; a touchpad two-finger click and slide pans. The app reads the device from the last scroll (`GDK_SCROLL_UNIT_SURFACE`).
- Alt+Left and the back button of the mouse go back to the place before.
- The tool keys of the web app: Grab G, Label E, and h and l step along the line.
- The Linux app shows the active plate only. It has layer profiles, Compare with Cura, USB printers, Send all plates, and Export all plates.

## Lessons

- **Keep the 3D view visible on Hyprland.** The view is an XRGB subsurface. Hyprland 0.56 counted the view as the whole window, marked it opaque, and drew it with no blending, so the transparent hole of the window covered the view. Present with pre-multiplied alpha (alpha 1 for each pixel), and set the opaque region of the view surface. `ZSLICE_PRESENT=fifo` or `immediate` picks the present mode for a test.
- **Write the session on a thread.** `zs_session_write` on the UI thread held it for 490 to 660 ms with a 3DBenchy. Take a snapshot on the UI thread (`zs_session_snapshot_take`, 33 ms), then write the bytes on a GTask thread (`zs_session_snapshot_write`). A serial number drops an old write.
- Keep the details shut on a warning: show a warning in the badge only.
- Keep the measure readout clear of the tape.
- Count an upload as sent only when the printer stored the file.
- The 3D view needs Wayland. X11 is open in the roadmap.

## Acceptance checks

1. `meson test -C build` passes: a redirect to another host gets no API key, and a Bambu printer with another certificate gets no access code.
2. CI builds with `-Dwerror=true`.
3. `ZSLICE_BENCH=1 build/zslice-gtk benchy.stl` logs an orbit of 240 frames. The goal is 60 frames a second. The log lists each frame over 40 ms.
4. `ZSLICE_STALLS=50` logs no stall during an orbit and a slice.
5. On Hyprland, the 3D view shows the scene with no menu open.
6. A quit and a start bring back the plates, the camera, and the last frame before the first slice.
7. `meson test -C linux/build` runs `model-download-test`: a name that resolves to a private, loopback, or unique local address gets no connection.
