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

## The steps

1. The plate set in the web app: one `Core` (`zs_app`) for each plate in the worker, the slice order, and the status. The project plates load into their own apps.
2. The renderer: the other plates as fixed bead buffers with offsets, the beds in a row, the camera moves, the far-plate simplification, and the frustum cull.
3. The web layout: the floating cards, the tool strip, the search, the drawer, the Parts popover, the plate labels, and the print card. The right pane goes.
4. The GTK app: the same plate set and layout. The Project panel of the GTK app (branch gtk-projects) becomes the plate labels and the Parts popover.
5. The docs: the user guide with screenshots of the new layout.
