# The macOS app

The macOS app has the features of the other apps, in the way of a Mac app. This page lists where it differs. The rest of the user guide applies.

## Build and open it

The app needs macOS 14 or later. Build it from the source tree (see [The macOS app](../internals/macos.md) in the internals):

```sh
cd macos
ZIG=/path/to/zig-0.16/zig ./build-core.sh
./make-app.sh
open build/zslice.app
```

Open an STL or 3MF file with File > Open (Command-O), with Open Recent, or with a drop on the icon of the app. Each file opens in a window, and a window can be a tab of another window (Window > Merge All Windows).

## The keys

The keys of the other apps work in the 3D view. A key with Ctrl in the other apps uses Command on the Mac:

| Action | macOS |
|---|---|
| Undo, Redo | Command-Z, Shift-Command-Z |
| Export the G-code | Command-E |
| Print | Command-P |
| Search the settings and the actions | `/` or Command-F |
| The keys | `?` or Help > Keyboard Shortcuts (Command-/) |
| The settings drawer | N or Option-Command-I |
| The 3D view, the 2D layer view | Command-1, Command-2 |
| Fit the part | Command-0 |
| Gaps, Check | G or Shift-Command-G, Shift-Command-K |
| New plate | Option-Command-N |
| Add models to the plate | Shift-Command-I |
| Open a project folder | Shift-Command-O |

Command and a click selects a part, Command and a drag moves it, and Command and the wheel turns it. Control and a click opens the context menu, as a right click does.

## The view

Four things float over the 3D view: the tools at the left, the layer slider at the right, the print card, and the dock at the bottom. The dock has the plates (the plate menu also shows all plates, adds one, and removes one; the printer of the plate; a new plate), the replay (play, the time in the top layer, the speed), and the history (undo, redo, and History). When the window is narrow, the print card sits above the dock. The toolbar has the colors of the lines with the legend (a click on a line type shows or fades it), 3D and 2D, the settings pane, Add Models, Search, and Printers. The print card hides on an empty plate.

## The drawer

The drawer is the inspector at the right of the window, and it has only the settings. It always sits beside the view, so it has no Pin. Its header has one back button (Command-[), when there is a page to go back to. The history is a popover: click History in the dock, or View > History (Command-Y). An open project is a sheet: File > Show Project.

The bar at the top of the Settings page picks what the editors change: This Print, Global (your settings for all prints, in `global.toml`), one part (with more than one part on the plate), or a layer profile. With a part or a profile, a change goes only there, the bar is in the accent color, and Done goes back to the print. New Profile from Here Up (or Down) in the context menu of a line makes a layer profile, and Part Settings on the part card opens the settings of the part. The editors of the search and of the print card follow the same bar.

## A part falls over

When you turn a part (the rings of the Turn tool, or its keys) so that it cannot stand, it falls over onto a side that holds it, and a note says so, unless support is on, which holds it in place.

## Edit one line

The card of a selected line has Don't Print This Line (or press Delete with the line selected), and −10 % and +10 % plastic. The plate slices again with the edit. Each edit is a step of the history, so Command-Z takes it back, and a project file keeps it. Add a Drop of Plastic Here in the context menu of a line puts a dot of 1 mm of plastic at that point, on the layer of the line, to fill a small gap. An edit holds to its line: after a change that moves the line, the edit waits. The History page lists the edits under Line Edits, marks the ones that wait, and × removes one.

## Draw support

The Support tool (U) draws an area of support on the part: click points on the part (they snap to the lines; Shift: no snap), then click the first point or press Return to close the area. Delete removes the last point, and Esc stops. Grid or Tree grows support under all of the part in the area that faces down, also where the support angle gives none; Block puts no support there. Click an outline to select its area, drag a point to move it, and press Delete (or Delete Area on the card) to remove it. While the tool is on, the support lines are faint (See through the support), so the outlines show. Each change is one step of the history.

## The print card

When a part is under 3 mm (a file in inches or in meters), the print card asks so, with Inches (×25.4) and Meters (×1000). The part card has the scale of the part in %.

With support off, when about 20 mm² or more of the part hangs in the air (overhangs and islands, not bridges), the print card says so in an amber box, with Turn On Support. A part off the bed shows its red warning instead.

The print card has the main settings of the print as small buttons. A click opens a popover with the editor and the slider of each setting; a change slices at once.

## Printers

Add a printer with the printer menu at the left of the toolbar. The picker starts with the popular printers (the brand row Popular), searches the whole library as you type, and lists the printers on your network. Manage your printers in zslice > Settings (Command-,), on the Printers page: the connection, Test the Connection, and Get a Key.

With a connection, the printer menu has Use the Printer's Bed, Nozzle, and Motion, and Use the Filament in the Printer: the settings of the plate take the values that the printer reports.

Each print that zslice exports or sends is signed: its last line is a signature of the app, made with a key that zslice keeps in the Keychain ("zslice signing key"). Get a Key gives the printer the public key of the app, and while the printer asks you to allow zslice, the app shows its key id, so you can check that the deck shows the same one. A printdeck that does not trust the key rejects the print, and the app says so. OctoPrint, Moonraker, and Bambu printers do not check signatures: the app says "not verified".

A printdeck with an https address: zslice trusts its certificate on the first connection, and a newer certificate after that (the deck renews it every 60 days). An older or another certificate stops the send with a warning; Get a Key trusts the printer again.

The API keys of your printers are in the Keychain of macOS (Keychain Access, "zslice printer API key"), never in a file. The list of your printers is in `~/Library/Application Support/zslice/printers.json`.

With a connection and its API key, the print card shows the state of the printer (its job and progress, or the roll in it and the grams left), and a printdeck gives its own estimate of the print time after each slice ("Workhorse: 1h 41m (3 min start)"). zslice sends the G-code to the printdeck for the estimate, compressed; the printer does not keep it or print it.

The picker also finds Bambu Lab printers in LAN mode. **The support of Bambu printers is untested with a real printer.** Turn on LAN mode on the printer; its screen shows the access code. Type the code in the picker (the serial number comes from the search, or from the printer). Upload sends a .gcode.3mf to the printer. Print uploads it and starts it, after you say each time that the plate is clear. The print card shows the state of the printer.

A Bambu printer has a certificate of its own that no authority signs. zslice trusts it on the first connection and says so, and from then on accepts only that certificate at that address. After a reset of the printer, Forget the trusted certificate in Settings > Printers.

The first search of the network asks for the permission to find devices on the local network. Allow it to see your printers in the picker.

## Filament and quality

The Filament and Quality menus sit beside the printer menu in the toolbar. They list the built-in profiles and your own, and have Save as Profile. The Quality menu shows a dot when this print has changes on top of the quality. Your profiles are in `~/Library/Application Support/zslice/profiles/filament` and `profiles/project`.

## A farm

The Printers page shows a summary of the farm (printing, ready to collect, failed, free, not answering); a click on one shows only those printers, and the printers that need a person come first. macOS notifies you when a print is ready to collect, or fails. File > Add Printers from a Fleet File adds many printers at once. To try it, run the farm simulator of the source tree (`tools/farm_sim/README.md`).

Before each print, zslice asks if the bed of the printer is clear. A printdeck starts the print at once when its setting Start prints from the slicer is on (the default, for a printer that you stand by). A deck set to ask (a farm) keeps the file until a person at the deck presses Print, and zslice says so.

The queue: Queue on a plate row (or Queue All) puts plates in the queue of the farm. Up Next then proposes each one to a free printer that fits it (the bed, the nozzle, the material), and nothing goes out until you press Send. A ready print has Collected, Bed Clear, which frees the printer for the next job. A failed job waits for another printer, 3 tries at most. The plate rows say where each job is.

## The printer of a plate

The printer menu in the plate bar assigns the plate to a printer: the plate slices for that printer (its bed, nozzle, and limits), the toolbar shows the printer of the plate in view, and the Printers page sends the plate there.

## The Printers page

The Printers page covers the view: the Printers button of the toolbar, or View > Printers (Option-Command-P), and Back to the Plate. It has a tile for each printer with a connection: its state, its job with the progress and the time left, or the filament in it. The tiles read again every 10 seconds while the page shows. A printer that does not answer fades and says so. Send the Plate on a tile sends the active plate. Plates to Print lists the plates with parts, each with a printer (the free ones first, then the busy ones with when they are free, and none whose bed is too small), its time and grams, and Send. A plate row shows its printer, and a plate that you sent says where and when. Each tile shows the plate that the printer prints (sent from zslice) and the plates up next for it. Each send asks you first if the bed of that printer is clear, and says when the plate is sliced for another printer.

## Your settings

The app keeps your settings in `~/Library/Application Support/zslice`: `machine.toml`, `filament.toml`, and `project.toml`, as in the other apps.

## Save a project

A window is a document. File > Save (Command-S) saves all its plates in one .3mf project file: the parts, their places and settings, the layer profiles, and the printer, filament, and print settings of each plate. Other slicers open its first plate. Save As, Duplicate, Rename, Revert To, and Browse All Versions are those of macOS, and the app saves your changes as you work (autosave). The close button has a dot while there are changes that are not saved, and an undo back to the saved state clears it.

An STL file, or a 3MF file that is not a zslice project, opens as a new untitled project with the name of the model. The model file itself never changes: the first save asks where to save the project. File > New (Command-N) opens an empty window.

To a New Plate on the part card moves a part to a new plate, with the settings of this one. Make [n] in all makes copies of the part until there are n: on its plate while they fit, then on new plates. The alert after a cut whose parts do not fit offers it too.

## Projects

Open a project with File > Open Project Folder (Shift-Command-O): choose the folder of a repository with a printdeck.yml. The plates of the project show in a row, and each plate slices. The project sheet (File > Show Project) lists the plates and the parts; the check box and the count of a part change the plates at once. File > Open Project from GitHub opens a public repository: type `owner/repo`, or its address on github.com (with `/tree/<branch>` for a branch).
