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
- Each tool has one key (Select `S`, Move `M`, Turn `R`, Scale `Shift+S`, Lay flat `F`, Cut `C`, Duplicate `D`, Draw supports `P`, Measure `T`, Gaps `G`, Check `K`, Edit lines `E`).
- `Tab` and `Shift+Tab` go through the parts of the active plate. The arrow keys move the selected part (with `Shift`: 10 times the step), and `R` with the arrow keys turns it.
- `[` and `]` go to the plate before and the next plate, and `Home` frames all plates.
- `Page Up` and `Page Down` (or `Up` and `Down` when the layer slider has the focus) go through the layers.
- `Ctrl+P` prints the active plate, `Ctrl+E` exports its G-code, and `Ctrl+Z` and `Ctrl+Shift+Z` undo and redo.
- `Esc` closes a card, the search, or the drawer, and then clears the selection.
- Each card and popover can take the focus, and `Tab` moves in it. The focus always shows.

## The core: one App for each plate

Each plate is one `App` (`zs_app`), with its own settings, profiles, parts, slice result, and cancel flag. A project plate has the profiles of its Cura stack, so the plates cannot share one set of settings.

- The C API stays per App. The `PlateSlot` swap in `App.selectPlate` stays for files that have more than one plate, until the shells use one App for each plate.
- The shells keep a plate set: the list of apps, the active one, and the order of the slices.
  - After a change, the active plate slices first. The other plates that are not up to date slice after it, one at a time, in the background.
  - A plate that is not up to date shows its old slice, dimmed a little, until its new one is done.
  - A change of a setting applies to the active plate. A change in the settings drawer can also apply to all plates that use the same profile (a choice in the drawer).
- Memory: the slice of each plate stays in memory. A plate far from the camera can drop its slice and keep only its draw buffer (see the renderer).

## The renderer

- The active plate is the full `View` that exists now: the pick index, the layer range, the selection, the replay, and the focus.
- Each other plate is a fixed bead buffer at an offset on x (`zs_view_set_plates`, to add): its beads, made from its App once after each slice. It has no pick index and no layer range. A click on it makes its plate the active one (the shell finds the plate from the bed point).
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
| Next to a line under the pointer | The line card: the feature, the width, the speed, the length, and a link to the setting that controls it. |
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
- The line card next to a selected line, with the three numbers and live editors of its first settings (linecard.js).
- The tool strip at the left of the view (Select, Move, Measure), with the key of each tool.
- The part card (partcard.js): duplicate (core: `zs_app_part_duplicate`), best orientation, less support, reset, remove, and the settings of the part, with a search for the part.
- The cards move with a drag of their head (drag.js).
- The measure on the tape, and the tape in the 2D view.
- The Turn tool (turn.js): rings for X, Y, and Z around the selected part, and keys for each axis.
- A double click on a side of a part lays the part down on that side.
- The view follows the dark mode of the system (core: `zs_view_set_dark`). The GTK app does not call it yet.

## The steps

1. The plate set in the web app: one `Core` (`zs_app`) for each plate in the worker, the slice order, and the status. The project plates load into their own apps.
2. The renderer: the other plates as fixed bead buffers with offsets, the beds in a row, the camera moves, the far-plate simplification, and the frustum cull.
3. The web layout: the floating cards, the tool strip, the search, the drawer, the Parts popover, the plate labels, and the print card. The right pane goes.
4. The GTK app: the same plate set and layout. The Project panel of the GTK app (branch gtk-projects) becomes the plate labels and the Parts popover.
5. The docs: the user guide with screenshots of the new layout.

## What is built (steps 1 and 2)

### The plate set in the web app

- `web/app/worker.js` keeps a list of plates. Each plate has a `Core` (`web/app/core.js`: one `zs_app` and one view to write its scenes), its own history, a name, and a status: empty, stale, slicing, done, failed, or resin.
- The ops of the page work on the active plate. A change marks the active plate stale. `runSlice` slices the active plate first, then each other stale plate in the order of the row, one at a time. A timer runs each slice after the messages that wait, so a change is never behind a slice of another plate.
- At the start of each slice, the worker sends the cancel flag of the app that slices. A change on the page sets it, so a background slice stops at once. The stopped plate is stale again, and it slices later.
- Events to the page: `plates` (the list, the active plate, the status, the bed size, and the printer of each), `plateScene` (the beads of another plate after its slice), and `stale` (the old slice of a new active plate that slices again). `sliced` is for the active plate only.
- Ops: `plateAdd` (an empty plate with the settings of the active plate; it becomes active), `plateActivate`, and `projectSet` (all plates of a printdeck.yml project, each in its own app). `load` (a file) makes a set of one plate.
- The history stays per plate: the worker keeps the history of each plate, and the active plate uses its own.
- `web/app/project.js`: "Open" on a plate loads all plates of the project into the set, and that plate is the active plate. With the set loaded, the button makes its plate active. A plate with no Cura stack (a resin plate) is in the set as a plate that cannot slice.

### The renderer

- `src/render/plates.zig` has the other plates (`Plate`) and the light beads of a slice (`Lite`).
- The world of the view is the frame of the active plate. Plate i draws at its origin in the row minus the origin of the active plate. A change of the active plate moves the camera by the same amount, so the picture does not jump. Then the camera moves (animated) to the new plate.
- Each other plate has its full beads, its light beads, and chunks of 512 beads with a box. A frame culls each plate by its box (the bed and the beads), and each chunk of a near plate by its box. It uses the full beads when a layer is 2.5 pixels high or more. Under that, it uses one light level in one draw.
- The light levels: level 1 leaves out the sparse infill and the inner walls of the layers with no skin, and joins straight runs of a path (to 0.1 mm). Level 2 keeps every second layer (twice the height, joined to 0.3 mm). Level 3 keeps every fourth layer (joined to 0.8 mm). A Benchy has 88 000 beads; the levels have about 34 000, 12 000, and 4 500.
- The worker view makes the light levels after each load, and the scene bytes carry them. The view of the page does not make them.
- The active plate also uses a light level when it is far: the light beads under its top layers, and the full beads of the top layers. Not with a selection, a highlight, or a replay: the light beads are not in the index space of these.
- The beds: the grid of each plate, in a lighter color for a plate that cannot slice, and the bed model of the view at each plate of the same printer.
- A plate with an old slice fades to the background a little (`fade` in the bead shader of `gl.js`).
- The C API (`include/zslice-app.h`): `zs_view_set_plates`, `zs_view_plate_scene_read`, `zs_view_plate_load`, `zs_view_plate_clear`, `zs_view_plate_flags`, `zs_view_plate_at`, `zs_view_plate_origin`, and `zs_view_frame_plate`. The web frame has a list of `zs_web_plate` items, their draws, and the grid lines of the plates.
- Only the web backend draws the other plates and the light beads. The Vulkan backend draws the active plate as before (step 4).

### Memory

- The worker has one wasm memory for all apps: 2 GB at most for the module with threads. An app keeps its job, its toolpaths, and its G-code after a slice.
- `zs_app_trim` (`App.trim`) frees the memos of the job of an app, and the buffers of the results before. The result stays, and the next slice makes the slow steps again. The worker trims each plate after its background slice, and the plate that stops being active.
- The view of a `Core` lives only while it writes a scene. The Core keeps a copy of the last scene bytes in JavaScript memory, out of the wasm memory, for a plate that becomes active while it slices again.
- Each Benchy plate adds 63 MB of wasm memory with a view of its own and no trim, and 30 MB with both changes.

### The page

- A small plate bar at the bottom left: the plate before, "Plate 2 of 6", the next plate, All, and "+ Plate".
- A label over the back edge of each plate (its number, its name, and its status). A click on a label goes to its plate.
- Keys: `[` and `]` go to the plate before and the next plate, and `Home` shows all plates. A double click on a plate goes to it. A click on another plate (its bed or its beads) makes it active.

### Changes to the plan

- The active plate does not fade while it slices again. It slices first, and a fade on each drag of a part would flicker.
- A resin plate shows as a light grid with its label ("Resin: not yet"). It shows no parts yet.
- The labels and the bar are a first form for step 3.
