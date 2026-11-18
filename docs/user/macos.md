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

## The print card

The print card has the main settings of the print as small buttons. A click opens a popover with the editor and the slider of each setting; a change slices at once.

## Printers

Add a printer with the printer menu at the left of the toolbar. The picker searches the library and lists the printers on your network. Manage your printers in zslice > Settings (Command-,), on the Printers page: the connection, Test the Connection, and Get a Key.

The API keys of your printers are in the Keychain of macOS (Keychain Access, "zslice printer API key"), never in a file. The list of your printers is in `~/Library/Application Support/zslice/printers.json`.

The first search of the network asks for the permission to find devices on the local network. Allow it to see your printers in the picker.

## Your settings

The app keeps your settings in `~/Library/Application Support/zslice`: `machine.toml`, `filament.toml`, and `project.toml`, as in the other apps.

## Projects

Open a project with File > Open Project Folder (Shift-Command-O): choose the folder of a repository with a printdeck.yml. The plates of the project show in a row, and each plate slices. The Project page of the drawer lists the plates and the parts; the check box and the count of a part change the plates at once. File > Open Project from GitHub opens a public repository: type `owner/repo`, or its address on github.com (with `/tree/<branch>` for a branch).

## Not yet in the macOS app

- The status of a printdeck printer and its estimate of the print time.
