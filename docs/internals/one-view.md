# One view: all plates, always sliced

This page is the plan for the main window of both apps (web and GTK). It replaces the right pane and the Preview and Project pages. The mockup is in the design canvas "zslice UI structure".

## The goals

- The whole app is one 3D view, a tool strip, and a few floating cards. A beginner sees the parts, a toolbar, and a Print button. The advanced tools are behind keys, the tool strip, the settings search, and a drawer that can be pinned.
- Each plate is always sliced. There is no Prepare mode and no Preview mode. A change starts a slice, and the view shows the lines when the slice is done.
- All plates are in one scene, in a row from left to right, with a gap between them. There is no mode for one plate or for all plates. These are camera positions:
  - a double click on a plate, or `[` and `]`, moves the camera to that plate and frames it;
  - `Home` frames all plates;
  - the camera moves are animated.
- Each edit gives real-time visual feedback (a drag updates the view at once).

## The keyboard

Each action of the app has a key, or a path from the keyboard. No action needs the mouse.

- `?` opens the sheet of all keyboard shortcuts, grouped (view, tools, parts, layers, plates, settings, history, print). The sheet comes from the same table that the menus and the tooltips use, so it is always complete. Type in the sheet to filter it.
- `/` opens the settings search. The arrow keys move in the results. Enter edits a value, and Left and Right change a slider or a list.
- Each tool has one key. The apps have Select `V`, Move `M`, Turn `R`, Support `S`, Grab `H`, Measure `T`, Paint `P`, Label `L`, Gaps `G`, and Duplicate `D` ([Keys and mouse](../user/keys.md)). Scale, Lay flat, Cut, Check, and Edit lines have no key yet.
- `Tab` and `Shift+Tab` go through the parts of the active plate. The arrow keys move the selected part (with `Shift`: 10 times the step), and `R` with the arrow keys turns it.
- `[` and `]` go to the plate before and the next plate, and `Home` frames all plates.
- `Page Up` and `Page Down` (or `Up` and `Down` when the layer slider has the focus) go through the layers.
- `Ctrl+P` prints the active plate, `Ctrl+E` exports its G-code, and `Ctrl+Z` and `Ctrl+Shift+Z` undo and redo.
- `Esc` closes a card, the search, or the drawer, and then clears the selection.
- Each card and popover can take the focus, and `Tab` moves in it. The focus always shows.

## The core: one App for each plate

Each plate is one `App` (`zs_app`), with its own settings, profiles, parts, slice result, and cancel flag. A project plate has the profiles of its Cura stack, so the plates cannot share one set of settings.

- The C API of the settings and the parts stays per App. The plate set is in the core (`zs_set`, `src/app/plate_set.zig`; see architecture.md): the list of apps, the active one, the status of each, and the order of the slices. The `PlateSlot` swap in `App.selectPlate` is still in `App`. No C API function and no shell uses it.
  - After a change, the active plate slices first. The other plates that are not up to date slice after it, one at a time, in the background.
  - A plate that is not up to date shows its old slice, dimmed a little, until its new one is done.
  - A change of a setting applies to the active plate. A change in the settings drawer can also apply to all plates that use the same profile (a choice in the drawer).
- Memory: the slice of each plate stays in memory. A plate far from the camera can drop its slice and keep only its draw buffer (see the renderer).

## The renderer

- The active plate is the full `View` that exists now: the pick index, the layer range, the selection, the replay, and the focus.
- Each other plate is a fixed bead buffer at an offset on x (`zs_view_set_plates`): its beads, made from its App once after each slice. It has no pick index and no layer range. A click on it makes its plate the active one (the shell finds the plate from the bed point).
- The beds: one bed model (or grid) for each plate, at its offset. The label of each plate (name, printer, status) is a floating card of the shell, placed at the projected point over the back edge of its bed (`zs_view_pixel_of`).
- Speed:
  - Draw a plate far from the camera with fewer beads: only the outer walls and the top skin of each layer, or every second layer.
  - Cull each plate to the view frustum by its box.
  - Draw the beads of one plate with one instanced draw call.
  - The target: 60 frames a second with 6 plates of the printdeck project and 20 parts on one plate.

## The layout

| Place | What |
|---|---|
| Top bar, left | The file or project name, and "Plate 1 of 6". A menu has open, add, export, and the recent files. |
| Top bar, right | The printer, filament, and quality chips, and the button of the settings drawer. |
| Top center of the view | The settings search (`/`): settings and actions. A setting shows its control in the result, for the plate or for the selected part. |
| Left of the view | The tool strip. Part tools: Select, Move, Turn (all axes), Scale, Lay flat, Cut, Duplicate, Draw supports. Then the line tools: Measure, Gaps, Check, Edit lines. Each tool shows its key on hover. |
| Next to a selected part | The part card: name, size, Lay flat, Duplicate, Cut, and the settings of the part ("+ Add a setting for this part" opens the search for the part). |
| In a corner of the view, away from a selected line | The line card: the feature, the layer and z, the speed and the flow and what slows them, the width and height, the layer time, the fan, a warning of the check there, what a support line holds up, and the settings that control the line, with a jump to each. |
| Beside the lit layers of a drag of the Select tool | The range card: "Layers A–B" and the settings that can change for some layers, as overrides of that z range. The view lights the layers with the highlight of a path and the bead range of the layers (`zs_view_light_layers`). |
| Beside a support that the Select tool picked | The support card: a tree branch (drag its dots; Delete) or the overhang of a grid support (Remove this support). |
| On the tape | The measure readout. |
| Right edge of the view | The layer slider of the active plate. |
| Over each plate | Its label: name, printer and material, status (To print, Printing, Printed, Failed, or "Resin: not yet"). |
| Bottom left | "6 plates, 1 printed", the Parts popover (the parts of printdeck.yml with their counts), and "+ Plate". |
| Bottom center | The history timeline. |
| Bottom right | The print card of the active plate: time, layers, grams, meters, and Print (with a menu: upload only, export). |
| Right, on demand | The settings drawer: all settings by section, with search. Pin docks it beside the view. |

## Done in the web app

- The settings search (`/`) with live controls in the results, which the user can move (search.js).
- The sheet of the keyboard shortcuts (`?`, shortcuts.js).
- The panel as a drawer: hidden, over the view, or pinned (`N`, the sliders button, Pin). The print card floats over the view.
- The line card in a corner of the view, away from the selected line, with the numbers of the line and live editors of its first settings (linecard.js).
- The tool strip at the left of the view (Select, Move, Measure), with the key of each tool.
- The part card (partcard.js): duplicate (core: `zs_app_part_duplicate`), best orientation, less support, reset, remove, and the settings of the part, with a search for the part.
- The range card (rangecard.js): a drag of the Select tool from a line lights layers, and the card edits overrides for them (setScoped with zmin and zmax).
- A selection of several parts (Shift and a click): a frame for each (`zs_view_part_boxes`), and the part card with the actions for all of them, each one call to the worker and one step of the history.
- The cards move with a drag of their head (drag.js).
- The measure on the tape, and the tape in the 2D view.
- The Turn tool (turn.js): rings for X, Y, and Z around the selected part, and keys for each axis.
- A double click on a side of a part lays the part down on that side.
- The view follows the dark mode of the system (core: `zs_view_set_dark`).

## Done in the GTK app (phase A of step 4)

The GTK app has the layout of the web app for one plate. The files are in `linux/src/ui`.

- `float.c`: the cards over the view are children of the overlay of the preview. A card has a point in the overlay, and it stays inside it. A drag of its head moves it.
- The panel is a drawer (`window.c`): hidden, over the view, or pinned beside it in the paned (`N`, the panel button, Pin). The mode stays in `app.ini` (`panel`, `panel_pinned`, `panel_width`). A hidden panel ends the focus of the settings browser (`send_focus` checks that its page is mapped).
- The print card floats at the bottom right of the view, with the facts of the print. A fact opens the search on its setting.
- `search.c`: the settings search (`/`), with the same score and the same groups of words as `search.js`. The setting editors (`setting-editor.c`) can now edit the value of one part, and a slider can send a value at most each 90 ms (`zg_setting_editor_slider_throttle`).
- `shortcuts.c`: the sheet of the keys (`?`), one table.
- The tool strip at the left of the view (`preview.c`): Select, Move, Turn, Measure, Gaps, and Check, each with its key.
- `line-card.c` and `part-card.c`: the cards of a line and of a part. The part card follows the part after each frame of the view (`zg_view3d_on_frame`, `zg_view3d_pixel_of`).
- `range-card.c`: the card of a range of layers (a drag of the Select tool from a line, in `view3d.c`). Its editors are scoped: the scope of the model is the z range of the layers while it is open.
- The Turn tool (`view3d.c`): the view widget draws the rings with cairo over the Vulkan subsurface.
- A double click on a side of a part turns the view to that side (`zs_view_look_at`).
- The measure readout floats on the tape, and the 2D view draws the tape and takes the clicks of the Measure tool.
- The views follow the theme of the app (`zg_theme_dark`, `zs_view_set_dark`), also for the 2D view.
- Get a key (`printer-link.c`, `zg_link_request_key`) in the Printers page of Preferences.

Differences from the web app:

- A turn or a move of a part slices at each step. The GTK view shows only the slice (no mesh of the part), so a held slice gives no feedback during a drag.
- The sheet of the keys is a window of its own.
- The GTK app has the plate set of the core (`zs_set`) and the plate bar of the web app (‹ Plate n of N › + Plate ×), with the keys `[`, `]`, `F`, and `Home`. The Vulkan backend draws the other plates too. The bar has **All**. `Home` shows all plates, and `F` shows the active plate. The plates have no labels in the view; the tooltip of "Plate n of N" lists the plates and their status.

## The steps

1. The plate set in the web app: one `Core` (`zs_app`) for each plate in the worker, the slice order, and the status. The project plates load into their own apps.
2. The renderer: the other plates as fixed bead buffers with offsets, the beds in a row, the camera moves, the far-plate simplification, and the frustum cull.
3. The web layout: the floating cards, the tool strip, the search, the drawer, the Parts popover, the plate labels, and the print card. The right pane goes.
4. The GTK app: the same plate set and layout. The Project panel of the GTK app (branch gtk-projects) becomes the plate labels and the Parts popover.
5. The docs: the user guide with screenshots of the new layout.

## What is built (steps 1 and 2)

### The plate set in the web app

The plate set was first in `web/app/worker.js`. It is in the core now (`zs_set`), and the worker keeps only the timers and the messages.

- The worker has one `zs_set` (`zs_set_new_web`). Each plate has its own app, history, name, and status: empty, stale, slicing, done, failed, or resin (`ZS_PLATE_STATUS_CANNOT`). A `Core` (`web/app/core.js`) wraps the app of a plate (`zs_set_app`).
- The ops of the page work on the active plate. A change calls `zs_set_changed`. `runSlice` calls `zs_set_step` from a timer: it slices the active plate first, then each other wanted plate in the order of the row, one at a time. A timer runs each slice after the messages that wait, so a change is never behind a slice of another plate.
- At the start of each slice, the worker sends the cancel flag of the app that slices (`zs_set_next`). A change on the page sets it, so a background slice stops at once. The stopped plate waits again, and it slices later.
- Events to the page: `plates` (the list from `zs_set_plate_info`, the active plate, and the changes for the view as bytes from `zs_set_sync_write`; the page applies them with `zs_view_sync_read`), and `stale` (the old slice of a new active plate that slices again, `zs_set_plate_scene`). `sliced` is for the active plate only.
- Ops: `plateAdd` (an empty plate with the settings of the active plate; it becomes active), `plateActivate`, `plateRemove` (the plate on the left becomes active), and `projectSet` (`zs_set_project_load` with the files of all plates). `load` (a file) keeps only the active plate for a project set (`zs_set_keep_active`).
- `web/app/project.js`: "Open" on a plate loads all plates of the project into the set, and that plate is the active plate. With the set loaded, the button makes its plate active. A plate with no Cura stack (a resin plate) is in the set as a plate that cannot slice. After a removal, the page maps the plates of the set to the plates of the plan; the print status of a removed plate stays in the Project tab.

### The renderer

- `src/render/plates.zig` has the other plates (`Plate`) and the light beads of a slice (`Lite`).
- The world of the view is the frame of the active plate. Plate i draws at its origin in the row minus the origin of the active plate. A change of the active plate moves the camera by the same amount, so the picture does not jump. Then the camera moves (animated) to the new plate.
- Each other plate has its full beads, its light beads, and chunks of 512 beads with a box. A frame culls each plate by its box (the bed and the beads), and each chunk of a near plate by its box. It uses the full beads when a layer is 2.5 pixels high or more. Under that, it uses one light level in one draw.
- The light levels: level 1 leaves out the sparse infill and the inner walls of the layers with no skin, and joins straight runs of a path (to 0.1 mm). Level 2 keeps every second layer (twice the height, joined to 0.3 mm). Level 3 keeps every fourth layer (joined to 0.8 mm). A Benchy has 88 000 beads; the levels have about 34 000, 12 000, and 4 500.
- The worker view makes the light levels after each load, and the scene bytes carry them. The view of the page does not make them.
- The active plate also uses a light level when it is far: the light beads under its top layers, and the full beads of the top layers. Not with a selection, a highlight, or a replay: the light beads are not in the index space of these. A plate of more than 500 000 beads uses level 1 also near the camera. A frame of all its full beads keeps a small GPU busy for more than a second, and the driver then resets the context (seen on an HD 530: "preemption time out" in the kernel log).
- An empty draw list draws no bead. Before, the web backend then drew all beads with the full mesh: with several plates, the active plate is often out of the view.
- The beds: the grid of each plate, in a lighter color for a plate that cannot slice, and the bed model of the view at each plate of the same printer.
- A plate with an old slice fades to the background a little (`fade` in the bead shader of `gl.js`).
- The C API (`include/zslice-app.h`): `zs_view_set_plates`, `zs_view_plate_scene_read`, `zs_view_plate_load`, `zs_view_plate_clear`, `zs_view_plate_flags`, `zs_view_plate_at`, `zs_view_plate_origin`, and `zs_view_frame_plate`. The web frame has a list of `zs_web_plate` items, their draws, and the grid lines of the plates.
- The frame backend (web and macOS) and the Vulkan backend (Linux) both draw the other plates.

### Memory

- The worker has one wasm memory for all apps: 4 GB at most for the module with threads (`wasm_mt_max` in build.zig). An app keeps its job, its toolpaths, and its G-code after a slice.
- `zs_app_trim` (`App.trim`) frees the memos of the job of an app, and the buffers of the results before. The result stays, and the next slice makes the slow steps again. The worker trims each plate after its background slice, and the plate that stops being active.
- The view of a `Core` lives only while it writes a scene. The Core keeps a copy of the last scene bytes in JavaScript memory, out of the wasm memory, for a plate that becomes active while it slices again.
- Each Benchy plate adds 63 MB of wasm memory with a view of its own and no trim, and 30 MB with both changes.

### The page

- A small plate bar at the bottom left: the plate before, "Plate 2 of 6", the next plate, All, and "+ Plate".
- A label over the back edge of each plate (its number, its name, and its status). A click on a label goes to its plate.
- Keys: `[` and `]` go to the plate before and the next plate, and `Home` shows all plates. A double click on a plate goes to it. A click on another plate (its bed or its beads) makes it active.

### Measurements

Chromium (headless, ANGLE on OpenGL) on an Intel HD 530, the view 840 x 850 pixels. GPU: the GPU time of a frame (a timer query), p50. Orbit: the time from one frame to the next in an orbit of 120 frames, p50 (16.7 ms is 60 frames a second).

| Scene | main | one-view |
|---|---|---|
| printdeck plate 1 alone (main), or all 6 plates with plate 1 in the view | GPU 22.6 ms, orbit 33 ms | GPU 7.1 ms, orbit 16.7 ms |
| All 6 plates (`Home`) | (one plate only) | GPU 6.1 ms, orbit 16.7 ms |
| Plate 5 (14 parts) in the view | (one plate only) | GPU 7.6 ms, orbit 16.7 ms |
| 20 Benchies on one plate, start view | GPU 205 ms, orbit 217 ms | GPU 40.6 ms, orbit 50 ms |

- The 6 plates of the printdeck project hold 60 frames a second in an orbit, in each camera position. A zoom close to a plate is slower (p95 50 to 67 ms): near the camera, the beads are full.
- 20 Benchies on one plate (1.76 million beads) do not reach 60 frames a second on this GPU. A 7th plate of 20 Benchies next to the 6 plates of the project does not slice: the worker reached the 2 GB of the wasm memory of the module with threads. The limit is now 4 GB (`wasm_mt_max` in build.zig), and this test did not run again. The 6 plates take about 920 MB at the high point.
- The G-code of a single plate is the same as on main (the Benchy, 2 758 371 bytes, the same hash).
- Plate 1 of the project slices to 108 layers, 5 h 22 min, 67.4 g, in the set as alone.

### Changes to the plan

- The active plate does not fade while it slices again. It slices first, and a fade on each drag of a part would flicker.
- A resin plate shows as a light grid with its label ("Resin: not yet"). It shows no parts yet.
- The labels and the bar are a first form for step 3.
