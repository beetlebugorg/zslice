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

## The drawer

The drawer is the inspector at the right of the window. It always sits beside the view, so it has no Pin. Settings and History are its two pages. Its header has a back button (Command-[).

The bar at the top of the Settings page picks what the editors change: This Print, Global (your settings for all prints, in `global.toml`), one part (with more than one part on the plate), or a layer profile. With a part or a profile, a change goes only there, the bar is in the accent color, and Done goes back to the print. New Profile from Here Up (or Down) in the context menu of a line makes a layer profile, and Part Settings on the part card opens the settings of the part. The editors of the search and of the print card follow the same bar.

## The print card

The print card has the main settings of the print as small buttons. A click opens a popover with the editor and the slider of each setting; a change slices at once.

## Printers

Add a printer with the printer menu at the left of the toolbar. The picker searches the library and lists the printers on your network. Manage your printers in zslice > Settings (Command-,), on the Printers page: the connection, Test the Connection, and Get a Key.

With a connection, the printer menu has Use the Printer's Bed, Nozzle, and Motion, and Use the Filament in the Printer: the settings of the plate take the values that the printer reports.

The API keys of your printers are in the Keychain of macOS (Keychain Access, "zslice printer API key"), never in a file. The list of your printers is in `~/Library/Application Support/zslice/printers.json`.

With a connection and its API key, the print card shows the state of the printer (its job and progress, or the roll in it and the grams left), and a printdeck gives its own estimate of the print time after each slice ("Workhorse: 1h 41m (3 min start)"). zslice sends the G-code to the printdeck for the estimate, compressed; the printer does not keep it or print it.

The picker also finds Bambu Lab printers in LAN mode. **The support of Bambu printers is untested with a real printer.** Turn on LAN mode on the printer; its screen shows the access code. Type the code in the picker (the serial number comes from the search, or from the printer). Upload sends a .gcode.3mf to the printer. Print uploads it and starts it, after you say each time that the plate is clear. The print card shows the state of the printer.

A Bambu printer has a certificate of its own that no authority signs. zslice trusts it on the first connection and says so, and from then on accepts only that certificate at that address. After a reset of the printer, Forget the trusted certificate in Settings > Printers.

The first search of the network asks for the permission to find devices on the local network. Allow it to see your printers in the picker.

## Filament and quality

The Filament and Quality menus sit beside the printer menu in the toolbar. They list the built-in profiles and your own, and have Save as Profile. The Quality menu shows a dot when this print has changes on top of the quality. Your profiles are in `~/Library/Application Support/zslice/profiles/filament` and `profiles/project`.

## The Printers page

The Printers page of the drawer has a tile for each printer with a connection: its state, its job with the progress and the time left, or the filament in it. The tiles read again every 10 seconds while the page shows. A printer that does not answer fades and says so. Send the Plate on a tile sends the active plate. Plates to Print lists the plates with parts, each with a printer (the free ones first, and none whose bed is too small) and Send. Each send asks you first if the bed of that printer is clear, and says when the plate is sliced for another printer.

## Your settings

The app keeps your settings in `~/Library/Application Support/zslice`: `machine.toml`, `filament.toml`, and `project.toml`, as in the other apps.

## Save a project

A window is a document. File > Save (Command-S) saves all its plates in one .3mf project file: the parts, their places and settings, the layer profiles, and the printer, filament, and print settings of each plate. Other slicers open its first plate. Save As, Duplicate, Rename, Revert To, and Browse All Versions are those of macOS, and the app saves your changes as you work (autosave). The close button has a dot while there are changes that are not saved, and an undo back to the saved state clears it.

An STL file, or a 3MF file that is not a zslice project, opens as a new untitled project with the name of the model. The model file itself never changes: the first save asks where to save the project. File > New (Command-N) opens an empty window.

To a New Plate on the part card moves a part to a new plate, with the settings of this one. Make [n] in all makes copies of the part until there are n: on its plate while they fit, then on new plates. The alert after a cut whose parts do not fit offers it too.

## Projects

Open a project with File > Open Project Folder (Shift-Command-O): choose the folder of a repository with a printdeck.yml. The plates of the project show in a row, and each plate slices. The Project page of the drawer lists the plates and the parts; the check box and the count of a part change the plates at once. File > Open Project from GitHub opens a public repository: type `owner/repo`, or its address on github.com (with `/tree/<branch>` for a branch).
