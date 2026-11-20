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
| The settings drawer | N or Option-Command-I; Esc or its × hides it |
| The 3D view, the 2D layer view | Command-1, Command-2 |
| Fit the part | Command-0 |
| Gaps, Check | G or Shift-Command-G, Shift-Command-K |
| New plate | Option-Command-N |
| Add models to the plate | Shift-Command-I |
| Open a project folder | Shift-Command-O |
| A page of layers up or down (5 % of the print), as in vi | Control-F, Control-B (Command-F is the search) |
| Select layers: the range grows up or down, and its card opens | Shift-K, Shift-J |
| The line before or after | Shift-H, Shift-L |

In the search, Return on a number or a text goes into its field with the value selected: type a new one, or step it with Up and Down. Return sends it and goes back to the search, for the next Up or Down. Esc goes back with no change.

A left or right drag (a two-finger press and drag on a trackpad) orbits the view, as in Cura. A middle drag, or Shift and a drag, pans. Command and a click selects a part, Shift and a click adds a part to the selection or takes it out, Command and a drag moves it, and Command and the wheel turns it. Control and a click opens the context menu, as a right click does.

The context menu fits what is under the pointer. On a support line it has Remove This Support: zslice finds the overhang that the line holds up and puts a Block area on it, and your support marks near the line go too. On a line of a part it has the support marks, a drop of plastic, the layer profiles, and the placement of the part. On the bed it has the plate items, with Remove This Plate when there are two plates or more. Show All Layers, the test prints, and Reset the View are in each menu.

## The view

Four things float over the 3D view: the tools at the left, the layer slider at the right, the print card, and the dock at the bottom. The dock has the plates (the plate menu also shows all plates, adds one, and removes one; the printer of the plate; a new plate), the replay (play, the time in the top layer, the speed), and the history (undo, redo, and History). When the window is narrow, the print card sits above the dock. The toolbar has the colors of the lines with the legend (a click on a line type shows or fades it), 3D and 2D, the settings pane, Add Models, Search, and Printers. The print card hides on an empty plate.

With two plates or more, each plate has a label in a row at the top of the view, over the middle of its plate, so the labels never cover a part. Click a label to show its plate; a right click removes the plate. A change of the list of plates goes into the session at once. File > Close the Project (also in the search) closes an open project: its plates stay in the window as your plates.

After each slice, zslice simulates the plastic of the print in the background (it falls where nothing holds it, sags, cools, and sets), and the view shows it in place of the planned lines when it is ready. In a replay the toolhead follows the plan while the plastic falls. The details then say at which layer the print fails, or how far the plastic droops. Show the Plan in the colors popover (or the search) shows the planned lines, and Show the Print as It Forms goes back. The Check also names a part that its brim holds up, or that can tip over.

## The drawer

The drawer is the inspector at the right of the window, and it has only the settings. It always sits beside the view, so it has no Pin. Its header has one back button (Command-[), when there is a page to go back to. The history is a popover: click History in the dock, or View > History (Command-Y). The dock shows a bubble for each step, in the color of its kind with its glyph; the step now is larger. Hold the pointer on a bubble to see its card: the changes in words, and an editor for each setting of the plate that the step changed, with its value now. A change there is a new step. Go to This Step (or a click on the bubble) goes back to it. An open project is a sheet: File > Show Project.

The bar at the top of the Settings page picks what the editors change: This Print, Global (your settings for all prints, in `global.toml`), one part (with more than one part on the plate), or a layer profile. With a part or a profile, a change goes only there, the bar is in the accent color, and Done goes back to the print. New Profile from Here Up (or Down) in the context menu of a line makes a layer profile, and Part Settings on the part card opens the settings of the part. The editors of the search and of the print card follow the same bar.

## A part falls over

When you turn a part (the rings of the Turn tool, or its keys) so that it cannot stand, it falls over in the view onto a side that holds it, and a note says so. With support on, it stays where you put it: the support holds it, and the note says that instead.

## The Select tool

Shift and a click select several parts: each gets a frame on the bed. The card of several parts has Duplicate, Arrange the Plate, To a New Plate, and Remove. Drag one of them with the Move tool (or Command and a drag), or press the arrow keys, to move them all. D and Delete act on all of them.

A click on a support line selects that support. With tree support, the dots of that tree show: drag a dot, a ring, or a segment to pull it, and right-click a dot for Delete Branch. With grid support, the overhang over the line shows in blue, and Delete (or Remove This Support on the card) takes the support away there. Make it: Grid, Tree, or Pad on the card changes the support there to that kind. zslice puts an area of that kind over the overhang, and the area takes the place of the support of your settings. Esc ends it.

A drag that starts on a line lights the layers from that line to the layer under the pointer. When you let go, a card opens beside them with settings that can change for some layers: infill, walls, top thickness, speeds, fan, and nozzle temperature. A change there is for those layers only. Esc, a click elsewhere, or × closes it.

## The card of a line

A click on a line opens its card in a corner of the view, clear of the line. It keeps that corner from click to click while the corner stays clear. Two short lines give the speed and the flow, then the size of the line, the time of its layer, and the fan. Notes say why the line is slow, when the flow limit sets its speed, what a support line holds up ("Holds up: outer wall on layer 64, 7 layers up."), and the warnings of the check at the line. Up to 5 settings follow, each with the reason it matters for this line and a live editor. A change slices at once, and the editor keeps the focus, so the arrow keys keep stepping.

## Edit one line

The card of a selected line has Don't Print This Line (or press Delete with the line selected), and −10 % and +10 % plastic. The plate slices again with the edit. Each edit is a step of the history, so Command-Z takes it back, and a project file keeps it. Add a Drop of Plastic Here in the context menu of a line puts a dot of 1 mm of plastic at that point, on the layer of the line, to fill a small gap. An edit holds to its line: after a change that moves the line, the edit waits. The History page lists the edits under Line Edits, marks the ones that wait, and × removes one.

## Draw support

The Support tool (S, or U) puts support on an overhang in one click: move the pointer over the part, the overhang near it lights up, and a click adds it as an area. Option and a click draw an area point by point: click points on the part (they snap to the lines; Shift: no snap), then click the first point or press Return to close the area. Delete removes the last point, and Esc stops. Grid or Tree grows support under all of the part in the area that faces down, also where the support angle gives none; Block puts no support there. Click an outline to select its area, drag a point to move it, and press Delete (or Delete Area on the card) to remove it. While the tool is on, the support lines are faint (See through the support), so the outlines show. Each change is one step of the history. Press S again, or click the tool, to show or hide its card; zslice keeps that choice.

With tree support, the Support tool shows the trees of each part as dots. Click a dot or a segment to select its branch. Drag a dot to move the node, drag the ring of the selected node to make it wider or narrower, and drag a segment to move the whole branch. The support slices again while you drag, so you can nudge a branch until it looks right. One drag is one undo step. Delete (or Delete Branch on the card) removes the branch and the branches over it. Add Branch plans a new one: click the bed for its foot, then the place on the part that needs support. Reset plans the trees of the part again, with no edits. Each edit keeps the rules of the planner: an edit that a rule limited shows red, and the card says which rule.

## The print card

When a part is under 3 mm (a file in inches or in meters), the print card asks so, with Inches (×25.4) and Meters (×1000). The part card has the scale of the part in %.

With support off, when about 20 mm² or more of the part hangs in the air (overhangs and islands, not bridges), the print card says so in an amber box, with Turn On Support. A part off the bed shows its red warning instead.

The print card has the main settings of the print as small buttons. A click opens a popover with the editor and the slider of each setting; a change slices at once.

## Printers

Add a printer with the printer menu at the left of the toolbar. For a printdeck, use Connect a Printdeck in that menu: type the address of the deck (on its System page), tap Allow on the screen of the deck, and pick the printers to add from the list of the deck, the one at the address of the deck too. Each printer gets its own address, its name on the deck, and the settings of its model. The picker starts with the popular printers (the brand row Popular), searches the whole library as you type, and lists the printers on your network. Manage your printers in zslice > Settings (Command-,), on the Printers page: the connection, Test the Connection, and Get a Key.

A printdeck or an OctoPrint printer that you add with no API key gets one in one step. A sheet opens at once and asks you to tap Allow on the screen of the printdeck (or in the web page of OctoPrint). It shows the key id to check, and counts down the 2 minutes. After Deny or the time-out, it says why and offers Try Again. A printdeck that drives more printers then lists them: check the ones to add. Each one gets the key and the machine settings of the deck.

With a connection, the printer menu has Use the Printer's Bed, Nozzle, and Motion, and Use the Filament in the Printer: the settings of the plate take the values that the printer reports.

Each print that zslice exports or sends is signed: its last line is a signature of the app, made with a key that zslice keeps in the Keychain ("zslice signing key"). Get a Key gives the printer the public key of the app, and while the printer asks you to allow zslice, the app shows its key id, so you can check that the deck shows the same one. A printdeck that does not trust the key rejects the print, and the app says so. OctoPrint, Moonraker, and Bambu printers do not check signatures: the app says "not verified".

A printdeck with an https address: zslice trusts its certificate on the first connection, and a newer certificate after that (the deck renews it every 60 days). An older or another certificate stops the send with a warning; Get a Key trusts the printer again.

The API keys of your printers are in the Keychain of macOS (Keychain Access, "zslice printer API key"), never in a file. The list of your printers is in `~/Library/Application Support/zslice/printers.json`.

With a connection and its API key, the print card shows the state of the printer (its job and progress, or the roll in it and the grams left), and a printdeck gives its own estimate of the print time after each slice ("Workhorse: 1h 41m (3 min start)"). zslice sends the G-code to the printdeck for the estimate, compressed; the printer does not keep it or print it.

The picker also finds Bambu Lab printers in LAN mode. **The support of Bambu printers is untested with a real printer.** Turn on LAN mode on the printer; its screen shows the access code. Type the code in the picker (the serial number comes from the search, or from the printer). Upload sends a .gcode.3mf to the printer. Print uploads it and starts it, after you say each time that the plate is clear. The print card shows the state of the printer.

A Bambu printer has a certificate of its own that no authority signs. zslice trusts it on the first connection and says so, and from then on accepts only that certificate at that address. After a reset of the printer, Forget the trusted certificate in Settings > Printers.

A Bambu Lab printer behind a printdeck: add it as a printdeck printer, and pick its Bambu Lab model. zslice then sends the deck a .gcode.3mf with the time, the grams, and the filament of the plate, and the deck sends it to the printer. The deck asks on its screen before the print starts, and picks the tray of the AMS with the same material and the nearest color.

Before each send to a printdeck that drives more than one printer, zslice reads the list of the deck and checks that the address leads to the printer that you picked. It stops the send, and says why, when the deck has no printer at that address, when the printer there is another one than the one you added from the deck, or when the name of your printer names another printer of the deck (by its words: Bambu Lab X2D names X2D), or when the address is the deck itself and zslice cannot tell that your printer is the first printer of the deck. Add the printer again from the deck to fix its address.

A printdeck that drives more than one printer shows a row for each of its printers in the picker, with its color; each one is a printer of its own, with its own address (`<deck>/printers/<id>`) and its own key.

The first search of the network asks for the permission to find devices on the local network. Allow it to see your printers in the picker.

## Filament and quality

A plate can print with more than one filament. The Filament button of the toolbar shows a dot in the color of each filament, and "N filaments" with more than one. A click opens its popover: the filaments of the plate, a note on how the printer changes the filament (by itself, or with a pause at each change), the built-in material profiles of filament 1, your filament profiles, and Save as Profile. For a printdeck printer, Use the Filaments of the printer reads the spools that it has loaded (the trays of an AMS and the external spool) and makes the filaments of the plate the same: the count, the material, and the color of each, in order. On a printer with two nozzles (the X2D), each filament has its nozzle (Main or 2nd): the spool of the second nozzle (the external spool) prints there. With a printer profile of one nozzle, that spool stays out. The print card lists the filaments of the plate too: the color, the material, and the grams of each in the last slice, and the number of filament changes. Add a Filament adds one, and × removes one (its parts and layers print with filament 1). The part card and the card of a range of layers have a row of color chips: a click prints the part or the layers with that filament. A Bambu Lab printer gets a .gcode.3mf on Export, with the filaments of the print in it.

The Paint tool (P) paints filaments on the surface of a part. It shows the mesh of the part in the colors of its paint, in place of the print. Smart Select lights the region under the pointer, and a click paints it with the filament of the card: a part of the mesh that stands out of its surface (a raised letter: its top and its sides) or sinks into it, else a flat or smooth face. Shift and a click add regions; a chip of another filament then paints all of them. Brush paints a sphere of its size along a drag, and splits the triangles on its edge for a clean border. A right drag turns the view. Each click or stroke slices again, and each painted region prints as its own part of the layer, with its walls and infill. Remove All Paint gives the part its own filament again. Esc, P, or another tool closes it.

The Filament and Quality menus sit beside the printer menu in the toolbar. They list the built-in profiles and your own, and have Save as Profile. The Quality menu shows a dot when this print has changes on top of the quality. Your profiles are in `~/Library/Application Support/zslice/profiles/filament` and `profiles/project`.

## A farm

The Printers page shows a summary of the farm (printing, ready to collect, failed, free, not answering); a click on one shows only those printers, and the printers that need a person come first. macOS notifies you when a print is ready to collect, or fails. File > Add Printers from a Fleet File adds many printers at once. To try it, run the farm simulator of the source tree (`tools/farm_sim/README.md`).

Before each print, zslice asks if the bed of the printer is clear. A printdeck starts the print at once when its setting Start prints from the slicer is on (the default, for a printer that you stand by). A deck set to ask (a farm) keeps the file until a person at the deck presses Print, and zslice says so.

The queue: Queue on a plate row (or Queue All) puts plates in the queue of the farm. Up Next then proposes each one to a free printer that fits it (the bed, the nozzle, the material), and nothing goes out until you press Send. A ready print has Collected, Bed Clear, which frees the printer for the next job. A failed job waits for another printer, 3 tries at most. The plate rows say where each job is.

## The printer of a plate

The printer menu in the plate bar assigns the plate to a printer: the plate slices for that printer (its bed, nozzle, and limits), the toolbar shows the printer of the plate in view, and the Printers page sends the plate there.

## The Printers page

The Printers page covers the view: the Printers button of the toolbar, or View > Printers (Option-Command-P), and Back to the Plate. Plates to Print is at the top. Under it, a card for each printer with a connection: its camera, its name and a state badge (Ready, Printing, Paused, Done: clear the bed, Failed, Offline), the job with its progress, the time left, and the layer, why it failed or paused, the temperatures, and the roll. The cards read again every 10 seconds while the page shows. A printer that does not answer fades and says so. Print the Plate on a card sends the active plate. Its menu (…) has Upload the Plate Only, Show the Camera Large, Open the Page of the Printer, Get a New Key, and Printer Settings. A printer that refuses the key, or has none, shows Get a Key in place of Print the Plate.

The camera plays only while its card shows on the page. Click it to see it large. It plays the MJPEG stream of a printdeck, OctoPrint, or Moonraker printer, or reloads its snapshot every 5 seconds when the printer gives only snapshots. A Bambu Lab printer sends its camera in LAN mode: a P1 or A1 as pictures, and an X1, H2, P2S, or X2D as H.264 video over RTSP (turn on LAN Only Liveview on the printer). A card shows at most 4 pictures a second, and the large view shows each one. When a camera gives no picture, the card says why and tries again after 20 seconds.

Plates to Print lists the plates with parts, each with a printer (the free ones first, then the busy ones with when they are free, and none whose bed is too small), its time and grams, and Send. A plate row shows its printer, and a plate that you sent says where and when. Each tile shows the plate that the printer prints (sent from zslice) and the plates up next for it. Each send asks you first if the bed of that printer is clear, and says when the plate is sliced for another printer.

## Your settings

The app keeps your settings in `~/Library/Application Support/zslice`: `machine.toml`, `filament.toml`, and `project.toml`, as in the other apps.

## Save a project

A window is a document. File > Save (Command-S) saves all its plates in one .3mf project file: the parts, their places and settings, the layer profiles, and the printer, filament, and print settings of each plate. Other slicers open its first plate. Save As, Duplicate, Rename, Revert To, and Browse All Versions are those of macOS, and the app saves your changes as you work (autosave). The close button has a dot while there are changes that are not saved, and an undo back to the saved state clears it.

An STL file, or a 3MF file that is not a zslice project, opens as a new untitled project with the name of the model. The model file itself never changes: the first save asks where to save the project. File > New (Command-N) opens an empty window.

To a New Plate on the part card moves a part to a new plate, with the settings of this one. Make [n] in all makes copies of the part until there are n: on its plate while they fit, then on new plates. The alert after a cut whose parts do not fit offers it too.

## Projects

Open a project with File > Open Project Folder (Shift-Command-O): choose the folder of a repository with a printdeck.yml. The plates of the project show in a row, and each plate slices. The project sheet (File > Show Project) lists the plates and the parts; the check box and the count of a part change the plates at once. File > Open Project from GitHub opens a public repository: type `owner/repo`, or its address on github.com (with `/tree/<branch>` for a branch).

## Quick Look

Select a G-code file in Finder and press the space bar. The preview shows the print in 3D. Drag to turn it, and scroll or pinch to zoom. The slider shows the layers up to one layer. Under it are the print time, the layers, the size, and the filament. G-code from any slicer works.

Finder shows a picture of each G-code file as its icon.

An STL file shows in the 3D viewer of macOS. A 3MF file that macOS does not show gets the zslice preview: zslice slices it with its default settings, and the slider shows its layers.

Quick Look finds the previews after the first start of zslice.app. If it does not, run `qlmanage -r`.

## Quit and come back

zslice keeps your session. After Command-Q, or a crash, it opens each window as it was: its plates and their unsaved changes, the camera, the layers, the page, and the tool. The last slice of each plate shows at once, and the new slice follows. Quit asks no "Save changes?": the session keeps them. When you close a window yourself, it leaves the session, and zslice asks about unsaved changes as usual.

## The bars

The toolbar is small, so the slice has the room. At the left is the file button with the name of the document: its menu opens files, adds models, saves, renames, and exports. Next to it are 3D and 2D and Search. At the right are the printer, the filament, and the quality, then Printers, Settings, and a menu of the rest (placement, checks, the history, and the keys). The colours of the lines are the palette icon on the tool strip.

The bar at the bottom has the plates and the history, the replay under them, and at the right end the time of the print with the plastic, the cost, and the layers under it, a badge, and Export (or Print). Click the time to see the details: the notes, the totals, your usual refinements, and the settings. A red or orange badge that says Check means a note on the print; the details stay shut until you click, so they do not cover the part. A blue badge counts your usual refinements.

## Your usual refinements

zslice notes how you refine each print after its first slice. When you made the same change in two or more other prints with the same material and nozzle, the details of the print offer it: click Apply (one undo step), Apply All, or × to never see it again. The records stay on your Mac, in `Application Support/zslice/refine.txt`.

## Grab a part

The Grab tool (H, the hand) picks a part up with a click: it stays in the hand with no button held. Move the pointer to carry it as a real object: it swings and turns about the point you hold. Hold Option while you move to turn it (Shift: steps of 15°), and use the wheel to lift it or put it lower. Click again, or press Esc, to let go: it keeps its speed, falls, and comes to rest flat on the plate; then the plate slices. With support on, it keeps the turn that you gave it, and support holds it.
