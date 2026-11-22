# 08. The 3D view

## Goal

Build the 3D view of a slice in the core (`src/render/`), so that each platform draws the same scene. The preview looks like the finished print: each segment is a bead of plastic with its real cross section and its cooled size. The view runs at 60 frames a second on a plate of many parts, picks a line under a pixel in under a millisecond, and shows all plates in one scene.

## Read first

- The header of `src/render/view.zig` (beads, camera, picks, the 2D view, the print view) and of `src/render/plates.zig` (plates and light levels).
- [The app](../docs/app/README.md), sections "The 3D view", "Inspect a path", and "Replay".
- [One view](../docs/internals/one-view.md), sections "The renderer" and "The layout".
- [Look at the print](../docs/user/look.md) and [Keys and mouse](../docs/user/keys.md).
- [The macOS app internals](../docs/internals/macos.md), section "The 3D view", for the Metal form of the same scene.

## Build

1. `src/render/view.zig`: the scene, the camera, the pick, the layer range, the replay, the focus, and the 2D view of one layer. It is the same on each platform.
2. Backends behind one interface (`src/render/frame.zig`): `vk.zig` (Vulkan, Linux), `d3d12.zig` (Direct3D 12, Windows, part 12), and `web.zig` (keeps the frame data in core memory, for WebGL2 on the web and Metal on the Mac). The core loads the Vulkan loader at run time. With no Vulkan, `zs_view_new` returns `ZS_NOT_SUPPORTED`, and the shell shows the 2D view only.
3. Beads: a flat top and bottom, round sides (`flow.zig`), round ends that overlap at corners, the deposited width from the bead area, the cooled size (shrinkage compensation removed), and the filament color with PLA-like light. 4x MSAA. The beads are in print order, so the layer slider changes only a count.
4. Color modes: filament, feature, speed, flow, layer time, line width, with the range of the ramp. An ironed top draws as a flat sheet.
5. Focus: the lines that a setting changes are solid, the others are ghosts that do not hide them.
6. Picks: a box for each run of 32 beads in print order, and a box for each layer. Test layers from the top down. A plate of a million beads tests a few thousand.
7. Camera: a target and a distance, with a unit quaternion for the direction. Orbit turns about the vertical axis and tilts with no roll (the code stops the tilt at 89 degrees). A free rotation turns about the screen axes. Zoom goes toward the pointer and stops 2 mm in front of the surface. A double click on a side of a part faces that side (`zs_view_look_at_side`); elsewhere it resets the view. Camera moves animate.
8. Plates (`src/render/plates.zig`): all plates in a row with a gap. The active plate is the full view. Each other plate is a fixed bead buffer at an offset. A plate out of the frustum has no draw cost.
9. Light levels for far beads: (1) the beads that show from outside, short runs joined to 0.1 mm; (2) every second layer at twice the height, joined to 0.3 mm; (3) every fourth layer, joined to 0.8 mm. The level comes from the size of a layer on the screen.
10. Signs: the shell draws the name, the printer, and the status of each plate into one RGBA image (`zs_view_set_signs`). The view draws each sign as a flat quad in front of the front edge of its plate. It keeps about the same height on the screen, fades when the camera looks along the bed, and turns round when the camera is behind the plate.
11. Decals: the labels draw as decals (`src/render/decal.zig`, the nonzero rule, holes stay open). The selected label gets a frame, four corner handles, and a turn handle as decals in its plane, with sizes in screen pixels, and the smart guide lines (part 05). A corner resizes about the opposite corner (Shift: each axis on its own). The turn handle turns the label about the center of its box (Shift: 15° steps). Alt (Option on the Mac) moves free of the guides.
12. The bed model of the printer (`src/bed.zig`): a static mesh and a texture, drawn after the beads in soft gray. B hides the bed and its grids, so the bottom of a part shows from below (`zs_view_set_bed_hidden`). The other plates keep their beds.
13. The mesh of the Paint, Label, and Support tools. A lit body shows in the color of a filament at once (`zs_view_light_color`).
14. Replay: `zs_view_set_time` shows the print at a time, with a nozzle marker, at 1x to 100x.
15. A print view of a G-code file of any slicer (`loadGcode`): the beads go straight into the GPU buffer. The host reports the byte offset it has read.

## Mouse and touch

This is the rule after several corrections. Match it in each shell.

- Left drag: orbit. In the Select tool, a drag that starts on a line selects layers.
- Right drag with a mouse: orbit, as in Cura.
- Two fingers clicked down and slid on a touchpad: pan. The browser and GTK give this as a right drag too. Tell them apart by the last scroll: a touchpad scrolls in small or sideways pixel steps (`GDK_SCROLL_UNIT_SURFACE` on Linux), a mouse wheel in whole steps. After a touchpad scroll, a right drag pans. After a wheel step, or before any scroll, it orbits. On the Mac, AppKit marks the touchpad drag with the subtype `.touch`.
- Middle drag, or Shift and a drag: pan.
- Wheel, a light two-finger swipe, or a pinch: zoom toward the pointer. Pinch zooms on a touch screen too.
- A right click with no drag: the menu of the view.

## Lessons

- **The bottom of each bead faces down.** From below, the first layer showed the infill through it. The bottom fan of the bead mesh had the same order as the top fan, so it faced up, and back-face culling removed it. Wind the bottom fan the other way.
- **Far beads keep their look.** Ribbons for far beads and flat normals under 5 px made a 3DBenchy look washed out and hatched. Ribbons are off by default (`zs_view_set_ribbons`), and only the gloss fades on beads under 5 px.
- **Fast when zoomed in.** Zoomed in on a 3DBenchy, the web view drew 77k full beads, and a shader with `discard` turned off the early depth test: 67 to 83 ms a frame on an Intel HD 530. Cull chunks of 96 beads, use a second program with no discard, and add a detail governor (`zs_view_set_detail`) while the view moves. The same zooms then took 50, 33, and 17 ms.
- **Keep the orbit center sane.** A zoom toward the pointer moves the orbit center only with the zoom. An orbit turns about the point of the print under the center of the view, or the center of the print, so the print never swings away.
- Keep the camera put when a slice comes back. Keep the start view of the camera at a plate switch.
- Slice a turned part coarse during the drag of a ring (`zs_app_set_coarse_part`): a 3DBenchy slices coarse in 85 ms in the browser and in 864 ms in full.
- Slice a draft during a drag or an edit that keeps all the paths in the view (`zs_app_set_draft`): an outline tolerance of 0.05 mm, no gap fill, and classic walls. A draft of a 3DBenchy needs a third of the CPU time. A draft has no G-code for a file or a printer (`zs_app_gcode` gives `ZS_NO_RESULT`): turn the draft off 300 ms after the last change, or at the end of the drag, and slice again. Show a small "Draft" note while the view has a draft, and keep the export, the print, and the numbers of the print card for the exact slice.
- Show the work that runs in a bar of 2 px at the top edge of the view, in the accent color: the draft slice, the exact slice, and the simulated print, each with the progress of the core. Fade it in after 150 ms of work and out at the end. Put small dim text next to it: what runs and its time, then the times of the last draft and exact slice. The bar and the text take no clicks and no room.
- Build the light levels again only for the changed layers.

## Acceptance checks

1. The 3DBenchy seen from below shows a solid first layer.
2. An orbit of 240 frames runs at 60 frames a second on the 3DBenchy (`ZSLICE_BENCH=1` in the GTK app, `window.zslice.bench` on the web).
3. A pick on a plate of many parts needs under a millisecond.
4. Six plates show in a row, and `[`, `]`, `F`, and `Home` frame them with animation.
5. A mouse right drag orbits. A touchpad two-finger click and slide pans.
6. The replay of a print ends at the time estimate of the G-code.
7. In each app, a change of a plate with a slice shows a draft first, the bar at the top edge, and then the exact slice 300 ms after the last change.
