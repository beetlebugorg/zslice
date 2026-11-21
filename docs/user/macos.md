# The macOS app

The macOS app has the features of the other apps, in the way of a Mac app. This page tells where it differs. The rest of the user guide applies.

## Build and open it

The app needs macOS 14 or later. Build it from the source tree (see [The macOS app](../internals/macos.md) in the internals):

```sh
cd macos
ZIG=/path/to/zig-0.16/zig ./build-core.sh
./make-app.sh
open build/zslice.app
```

Open an STL or 3MF file in one of these ways:

- File > Open (Command-O), or File > Open Recent.
- Drop the file on the icon of the app.

Each file opens in a window. A window can be a tab of another window (Window > Merge All Windows). File > New (Command-N) opens an empty window.

## The window

The 3D view fills the window. The controls float over it, so the slice has the room.

### The toolbar

From left to right:

- **The file button**, with the name of the document. Its menu opens files, adds models, saves, renames, and exports.
- **3D and 2D**: the 3D view and the 2D layer view.
- **Search** (`/` or Command-F): the settings and the actions.
- **The printer menu**: your printers, Add a Printer, Connect a Printdeck, and Manage Printers. With a connected printer, it can also take the bed, the nozzle, the motion, or the filament that the printer reports.
- **The Filament button**: a dot in the color of each filament of the plate. See [Filaments](#filaments).
- **The Quality menu**: the built-in qualities and yours, and Save as Profile. A dot means that this print has changes on top of the quality.
- **Printers**: the [Printers page](#the-printers-page).
- **Settings**: the settings drawer.
- **A menu of the rest**: placement, checks, the history, and the keys.

### The tool strip

The tools are at the left of the view. Each has a key:

| Tool | Key | What it does |
|---|---|---|
| Select | V | Select a line, parts, a support, or a range of layers. |
| Move | M | Drag a part on the bed. |
| Turn | R | Turn a part with its rings, or with keys. |
| Grab | H | Pick a part up and carry it. |
| Measure | T | Measure between two points. |
| Support | S (or U) | Draw or remove support. |
| Paint | P | Paint filaments on a part. |

Under the tools are the palette (the colors of the lines and the legend), Gaps (G), and Check.

### The bottom bar

The bar at the bottom has two rows:

- **The plates**: the plate menu (all plates, add a plate, remove a plate), the printer of the plate, and a new plate.
- **The history**: Undo, Redo, a bubble for each step, and History.
- **The replay**: play, the time in the top layer, and the speed.

At the right end are the time of the print, with the plastic, the cost, and the layers under it. Next to them are a badge and Export (Command-E). With a connected printer, Export is Print (Command-P), and its menu has Upload Only and Export G-code.

Click the time to open the details: the notes, the totals, your usual refinements, the main settings, and the filaments. A red or orange badge that says Check means a note on the print. The details stay shut until you click, so they never cover the part. A blue badge counts your usual refinements.

### The cards

A click opens a card for what you clicked: a line, a part, a support, or a range of layers. A card never covers the thing that you clicked. It also keeps out of the details, the check panel, and the card of a tool. Esc or × closes it.

Put a card where you want it, and zslice keeps it there:

- Drag the head of a card to move it. The next card of that kind opens at the same place, unless there it would cover what you clicked. Then it opens beside that thing for this time.
- Drag the grip at the lower right corner to resize a card. Its kind keeps the size.
- Double-click the head to forget the place and the size.

The line card, the part card, the card of a range of layers, and the card of a history step each keep their own place and size.

### The settings drawer

The drawer is the inspector at the right of the window. It has only the settings, and it always sits beside the view. N or Option-Command-I shows it; Esc or its × hides it. Its header has a back button (Command-[) when there is a page to go back to.

The bar at the top of the drawer picks what the editors change:

- **This Print**: the plate.
- **Global**: your settings for all prints (`global.toml`).
- **A part**: with more than one part on the plate. Part Settings on the part card opens it.
- **A layer profile**: New Profile from Here Up (or Down) in the context menu of a line makes one.

With a part or a profile, the bar is in the accent color, a change goes only there, and Done goes back to the print. The editors of the search and of the details follow the same bar.

## Get around

### The mouse and the trackpad

- A left drag orbits the view. So does a right drag of a mouse, as in Cura.
- On a trackpad, click down with two fingers and slide them to pan. A middle drag, or Shift and a drag, pans too.
- The wheel zooms, and so do a pinch and two fingers that rest and slide on a trackpad (with no click).
- Control and a click, or a right click, opens the context menu.
- Command and a click selects a part. Command and a drag moves it in any tool, and Command and the wheel turns it by 15°.

The context menu fits what is under the pointer:

- **On a support line**: Remove This Support. zslice finds the overhang that the line holds up and puts a Block area on it. Your support marks near the line go too.
- **On a line of a part**: the support marks, a drop of plastic, the layer profiles, and the placement of the part.
- **On the bed**: the plate items, and Remove This Plate when there are two plates or more.
- **In each menu**: Show All Layers, the test prints, and Reset the View.

### The keys

The keys of the other apps work in the 3D view. A key with Ctrl in the other apps uses Command on the Mac. Press `?` (or Help > Keyboard Shortcuts, Command-/) to see all of them.

| Action | Key |
|---|---|
| Undo, Redo | Command-Z, Shift-Command-Z |
| Export the G-code | Command-E |
| Print | Command-P |
| Search the settings and the actions | `/` or Command-F |
| The settings drawer | N or Option-Command-I |
| The 3D view, the 2D layer view | Command-1, Command-2 |
| Fit the part | Command-0 |
| Gaps, Check | G or Shift-Command-G, Shift-Command-K |
| The Printers page | Option-Command-P |
| The history | Command-Y |
| New plate | Option-Command-N |
| Add models to the plate | Shift-Command-I |
| Open a project folder | Shift-Command-O |
| A page of layers up or down (5 % of the print), as in vi | Control-F, Control-B (Command-F is the search) |
| Select layers: the range grows up or down, and its card opens | Shift-K, Shift-J |
| The line before or after | Shift-H, Shift-L |

### The search

Type `/` and the words of a setting or an action. Up and Down go through the results. Return runs an action or turns a switch on or off.

Return on a number or a text goes into its field with the value selected. Type a new value, or step it with Up and Down. Return sends it and goes back to the search, for the next Up or Down. Esc goes back with no change.

## Select and edit

### A line

A click on a line opens its card in a corner of the view, clear of the line. The card keeps its corner from click to click while that corner stays clear. It has:

- The speed and the flow, the size of the line, the time of its layer, and the fan.
- Notes: why the line is slow, when the flow limit sets its speed, and what a support line holds up ("Holds up: outer wall on layer 64, 7 layers up.").
- The warnings of the check at the line.
- Up to 5 settings, each with the reason that it matters for this line and an editor. A change slices at once. The editor keeps the focus, so the arrow keys keep stepping.

The card can also edit the line itself:

- **Don't Print This Line** (or Delete).
- **−10 %** and **+10 %** plastic.
- **Add a Drop of Plastic Here** (in the context menu of a line): a dot of 1 mm of plastic, to fill a small gap.

Shift-click a line to select its whole run: one extrusion, from the retraction before the line to the next one. The other lines of the run light up with it, and a note says how many lines it has. A new selection ends the run.

Each edit is a step of the history, so Command-Z takes it back, and a project file keeps it. An edit holds to its line: after a change that moves the line, the edit waits. The History page lists the edits under Line Edits, marks the ones that wait, and × removes one.

### Parts

- **Several parts**: Command-Shift and a click adds a part to the selection, or takes it out. In the Move and Turn tools, Shift and a click does it too. Each selected part gets a frame on the bed. The card of several parts has Duplicate, Arrange the Plate, To a New Plate, and Remove. A drag of one of them, or the arrow keys, moves them all. D and Delete act on all of them.
- **Scale**: the part card has the scale of the part in %. When a part is under 3 mm (a file in inches or in meters), the details ask so, with Inches (×25.4) and Meters (×1000).
- **Copies**: Make [n] in all on the part card makes copies of the part until there are n: on its plate while they fit, then on new plates. To a New Plate moves the part to a new plate with the settings of this one.
- **A part falls over**: when you turn a part so that it cannot stand, it falls over onto a side that holds it, and a note says so. With support on, it stays where you put it, and the note says that the support holds it.

### Grab a part

The Grab tool (H) picks a part up with a click. It stays in the hand with no button held.

1. Move the pointer to carry it as a real object: it swings and turns about the point that you hold.
2. Hold Option while you move to turn it (Shift: steps of 15°). The wheel lifts it or puts it lower.
3. Click again, or press Esc, to let go. It keeps its speed, falls, and comes to rest flat on the plate. Then the plate slices.

With support on, it keeps the turn that you gave it, and support holds it.

### A range of layers

With the Select tool, a drag that starts on a line lights the layers from that line to the layer under the pointer. It lights only the body that the line belongs to: a drag up the outer wall of a box lights the wall, and not the posts inside it. When you let go, a card opens beside them. Shift-K and Shift-J make a range with the keys. From a selected line they light its body too; with no line selected, they light the whole layers.

The card has the settings that can change for some layers: the filament, infill, walls, top thickness, speeds, fan, and nozzle temperature. A change there is for those layers only. Esc, a click elsewhere, or × closes it.

### Support

**Select a support.** With the Select tool, a click on a support line selects that support:

- With tree support, the dots of that tree show. Drag a dot, a ring, or a segment to pull it. Right-click a dot for Delete Branch.
- With grid support, the overhang over the line shows in blue. Delete (or Remove This Support on the card) takes the support away there.
- Make It: Grid, Tree, or Pad changes the support there to that kind. zslice puts an area of that kind over the overhang, and the area takes the place of the support of your settings.
- Esc ends it.

**The Support tool** (S, or U) puts support on an overhang in one click. Move the pointer over the part: the overhang near it lights up. Click to add it as an area.

- Option and a click draw an area point by point. The points snap to the lines (Shift: no snap). Click the first point, or press Return, to close the area. Delete removes the last point, and Esc stops.
- Grid or Tree grows support under all of the part in the area that faces down, also where the support angle gives none. Block puts no support there.
- Click an outline to select its area. Drag a point to move it. Delete (or Delete Area on the card) removes it.
- While the tool is on, the support lines are faint, so the outlines show.
- Press S again, or click the tool, to show or hide its card. zslice keeps that choice.

**Trees.** With tree support, the Support tool shows the trees of each part as dots:

- Click a dot or a segment to select its branch.
- Drag a dot to move the node, the ring of the selected node to make it wider or narrower, and a segment to move the whole branch. The support slices again while you drag. One drag is one undo step.
- Delete (or Delete Branch) removes the branch and the branches over it.
- Add Branch plans a new one: click the bed for its foot, then the place on the part that needs support.
- Reset plans the trees of the part again, with no edits.
- Each edit keeps the rules of the planner. An edit that a rule limited shows red, and the card says which rule.

Each change of support is one step of the history.

## Filaments and paint

### Filaments

A plate can print with more than one filament. The Filament button of the toolbar shows a dot in the color of each filament, and "N filaments" with more than one. Its popover has:

- **The filaments of the plate**: the color, the material, and the grams of each in the last slice, and the number of filament changes. Add a Filament adds one. × removes one; its parts and layers print with filament 1.
- **A note** on how the printer changes the filament: by itself (a printer with an AMS), or with a pause at each change.
- **Use the Filaments of the printer** (a printdeck printer): it reads the spools that the printer has loaded (the trays of an AMS, and the external spool). Then it makes the filaments of the plate the same: the count, and the material and the color of each, in order. For a Bambu Lab printer, it also sets the nozzle type and the nozzle flow from the nozzle that the printer reports (for example hardened steel, high flow), so the file names the right nozzle.
- **The built-in material profiles** of filament 1, your filament profiles, and Save as Profile.

The details list the filaments too.

To print a part or some layers with a filament, use the row of color chips on the part card or on the card of a range of layers.

The support can print with a filament of its own (one that breaks away, or that dissolves): pick it in Support filament, in the support settings or in the support button of the details. Its first chip, Part, prints the support with the filament of the part. Support interface filament picks the filament of the layers that touch the part; its first chip, Support, uses the support filament.

On a printer with two nozzles (the X2D), each filament has its nozzle: Main or 2nd. The external spool feeds the second nozzle, so Use the Filaments puts its filament there. With a printer profile of one nozzle, that spool stays out.

A Bambu Lab printer gets a .gcode.3mf on Export, with the filaments of the print in it.

### The Paint tool

The Paint tool (P) paints filaments on the surface of a part. It shows the mesh of the part in the colors of its paint, in place of the print.

- **Smart Select** lights the region under the pointer, and a click paints it with the filament of the card. A region is a part of the mesh that stands out of its surface or sinks into it (a raised letter: its top and its sides), else a flat or smooth face. Shift and a click add regions; a chip of another filament then paints all of them.
- **Brush** paints a sphere of its size along a drag. It splits the triangles on its edge, for a clean border.
- Option and a drag turns the view. A right drag of a mouse turns it too, and two fingers clicked down and slid on a trackpad pan it.
- Each click or stroke slices again. Each painted region prints as its own part of the layer, with its walls and infill.
- Remove All Paint gives the part its own filament again.
- Esc, P, or another tool closes it.

A painted 3MF file of PrusaSlicer or Bambu Studio opens with its paint and its colors.

## Printers

### Add a printer

The printer menu has two ways:

- **Add a Printer**: the picker. It starts with the popular printers, searches the whole library as you type, and lists the printers on your network. The first search asks for the permission to find devices on the local network; allow it to see your printers.
- **Connect a Printdeck**: for a printdeck.
  1. Type the address of the deck. It is on the System page of the deck.
  2. Tap Allow on the screen of the deck. Check that it shows the same key id as zslice.
  3. Pick the printers to add from the list of the deck, the one at the address of the deck too.

  Each printer gets its own address, its name on the deck, and the settings of its model.

Manage your printers in zslice > Settings (Command-,), on the Printers page: the connection, Test the Connection, and Get a Key.

A printdeck or an OctoPrint printer that you add with no API key gets one in one step. A sheet opens at once and asks you to tap Allow on the screen of the printdeck (or in the web page of OctoPrint). It shows the key id to check, and counts down the 2 minutes. After Deny or the time-out, it says why and offers Try Again.

### The printer of a plate

The printer menu in the plate bar gives the plate a printer. The plate slices for that printer (its bed, nozzle, and limits), the toolbar shows the printer of the plate in view, and the Printers page sends the plate there.

The settings say whose they are. A section of printer settings starts with a banner, "Printer · *name*: each printer keeps its own values here", and a filament section the same with the filament. In a search, and on the page of a setting, a badge names the printer or the filament. Print settings have no badge: they stay when you change the printer.

Each printer keeps its filament. When you change the printer, zslice keeps the filament settings for the printer you leave, and loads the filament that the new printer was last used with. A printer that has none yet keeps the filament you have now.

With a connection and its API key, the details show the state of the printer: its job and progress, or the roll in it and the grams left. A printdeck also gives its own estimate of the print time after each slice ("Workhorse: 1h 41m (3 min start)"). For the estimate, zslice sends the G-code to the printdeck, compressed; the printer does not keep it or print it.

### Send a print

Before each print, zslice asks if the bed of the printer is clear.

- A printdeck starts the print at once when its setting Start prints from the slicer is on (the default, for a printer that you stand by).
- A deck set to ask (a farm) keeps the file until a person at the deck presses Print, and zslice says so.
- zslice counts a send as done only when the printer says that it stored the file. A printer that answers with something else (a login page of a proxy, for one) gets an error with its answer.

Before each send to a printdeck that drives more than one printer, zslice reads the list of the deck. It checks that the address leads to the printer that you picked. It stops the send, and says why, when:

- the deck has no printer at that address;
- the printer there is another one than the one that you added from the deck;
- the name of your printer names another printer of the deck (by its words: Bambu Lab X2D names X2D); or
- the address is the deck itself, and zslice cannot tell that your printer is the first printer of the deck.

Add the printer again from the deck to fix its address.

### Keys, signatures, and certificates

- **Signatures**: each print that zslice exports or sends is signed. Its last line is a signature of the app, made with a key that zslice keeps in the Keychain ("zslice signing key"). Get a Key gives the printer the public key of the app. A printdeck that does not trust the key rejects the print, and the app says so. OctoPrint, Moonraker, and Bambu printers do not check signatures: the app says "not verified".
- **API keys**: the API keys of your printers are in the Keychain of macOS (Keychain Access, "zslice printer API key"), never in a file. A key goes when its printer goes. zslice sends a key only to the address of its printer, also after a redirect. The list of your printers is in `~/Library/Application Support/zslice/printers.json`.
- **Certificates of a printdeck**: zslice trusts the certificate of a printdeck with an https address on the first connection, and a newer certificate after that (the deck renews it every 60 days). An older or another certificate stops the send with a warning. Get a Key trusts the printer again.

### Bambu Lab printers

**The support of Bambu printers is untested with a real printer.**

- **Direct**: the picker finds Bambu Lab printers in LAN mode. Turn on LAN mode on the printer; its screen shows the access code. Type the code in the picker. The serial number comes from the search, or from the printer. Upload sends a .gcode.3mf to the printer. Print uploads it and starts it, after you say each time that the plate is clear. The details show the state of the printer.
- **Behind a printdeck**: add it from the deck (Connect a Printdeck), or as a printdeck printer with its Bambu Lab model. zslice sends the deck a .gcode.3mf with the time, the grams, and the filaments of the plate, and the deck sends it to the printer. The deck asks on its screen before the print starts, and picks the tray of the AMS with the same material and the nearest color.
- **The certificate**: a Bambu printer has a certificate of its own that no authority signs. zslice trusts it on the first connection and says so. From then on it accepts only that certificate at that address. After a reset of the printer, Forget the trusted certificate in Settings > Printers.

## The Printers page

The Printers page covers the view: the Printers button of the toolbar, or View > Printers (Option-Command-P). Plate goes back.

- **The summary**: how many printers print, are ready to collect, failed, are free, or do not answer. A click on one shows only those printers.
- **Plates to Print**: each plate with parts, with a printer (the free ones first, then the busy ones with when they are free, and none whose bed is too small), its time and grams, and Send. A plate row shows its printer, and a plate that you sent says where and when.
- **A card for each printer** with a connection: its camera, its name and a state badge (Ready, Printing, Paused, Done: clear the bed, Failed, Offline), the job with its progress, the time left, and the layer, why it failed or paused, the temperatures, and the roll. It also shows the plate that the printer prints and the plates up next for it.

The cards read the printers again every 10 seconds while the page shows. A printer that does not answer fades and says so. The printers that need a person come first.

On a card:

- **Print the Plate** sends the active plate. A printer that refuses the key, or has none, shows Get a Key in its place.
- **The menu (…)** has Upload the Plate Only, Show the Camera Large, Open the Page of the Printer, Get a New Key, and Printer Settings.
- **The camera** plays only while its card shows. Click it to see it large. It plays the MJPEG stream of a printdeck, OctoPrint, or Moonraker printer, or loads its snapshot every 5 seconds when the printer gives only snapshots. A Bambu Lab printer sends its camera in LAN mode: a P1 or A1 as pictures, and an X1, H2, P2S, or X2D as video (turn on LAN Only Liveview on the printer). A card shows at most 4 pictures a second; the large view shows each one. When a camera gives no picture, the card says why and tries again after 20 seconds.

### A farm

- macOS notifies you when a print is ready to collect, or fails.
- **The queue**: Queue on a plate row (or Queue All) puts plates in the queue of the farm. Up Next then proposes each one to a free printer that fits it (the bed, the nozzle, the material). Nothing goes out until you press Send.
- A ready print has Collected, Bed Clear, which frees the printer for the next job.
- A failed job waits for another printer, 3 tries at most. The plate rows say where each job is.
- File > Add Printers from a Fleet File adds many printers at once. To try it, run the farm simulator of the source tree (`tools/farm_sim/README.md`).

## The print as it forms

After each slice, zslice simulates the plastic of the print in the background: it falls where nothing holds it, sags, cools, and sets. When it is ready, the view shows it in place of the planned lines. In a replay the toolhead follows the plan while the plastic falls.

- The details say at which layer the print fails, or how far the plastic droops.
- With support off, when about 20 mm² or more of the part hangs in the air (overhangs and islands, not bridges), the details say so in an amber box, with Turn On Support. A part off the bed shows its red warning instead.
- Show the Plan, in the palette popover or the search, shows the planned lines. Show the Print as It Forms goes back.
- The check also names a part that its brim holds up, or that can tip over.

## Plates and history

**Plates.** With two plates or more, each plate has a label in a row at the top of the view, over the middle of its plate, so the labels never cover a part. Click a label to show its plate; a right click removes the plate.

**History.** The bottom bar shows a bubble for each step, in the color of its kind with its glyph. The step now is larger. Hold the pointer on a bubble to see its card:

- the changes in words;
- an editor for each setting of the plate that the step changed, with its value now (a change there is a new step);
- Go to This Step. A click on the bubble goes there too.

History in the bottom bar (or View > History, Command-Y) opens the list of all the steps and the line edits.

## Files and projects

### Save

A window is a document. File > Save (Command-S) saves all its plates in one .3mf project file: the parts, their places and settings, the layer profiles, and the printer, filament, and print settings of each plate. Other slicers open its first plate.

- Save As, Duplicate, Rename, Revert To, and Browse All Versions are those of macOS. The app saves your changes as you work (autosave).
- The close button has a dot while there are changes that are not saved. An undo back to the saved state clears it.
- An STL file, or a 3MF file that is not a zslice project, opens as a new untitled project with the name of the model. The model file itself never changes. The first save asks where to save the project.

### Projects

- **A project folder**: File > Open Project Folder (Shift-Command-O), then the folder of a repository with a printdeck.yml. The plates of the project show in a row, and each plate slices.
- **From GitHub**: File > Open Project from GitHub opens a public repository. Type `owner/repo`, or its address on github.com (with `/tree/<branch>` for a branch).
- **The project sheet** (File > Show Project) lists the plates and the parts. The check box and the count of a part change the plates at once.
- File > Close the Project (also in the search) closes it. Its plates stay in the window as your plates.

### Quit and come back

zslice keeps your session. After Command-Q, or a crash, it opens each window as it was: its plates and their unsaved changes, the camera, the layers, the page, and the tool. The last slice of each plate shows at once, and the new slice follows.

Quit asks no "Save changes?": the session keeps them. When you close a window yourself, it leaves the session, and zslice asks about unsaved changes as usual. A change of the list of plates goes into the session at once.

### Your settings and records

All of these are in `~/Library/Application Support/zslice`:

- `machine.toml`, `filament.toml`, and `project.toml`: your settings, as in the other apps.
- `global.toml`: your settings for all prints.
- `profiles/filament` and `profiles/project`: your filament and quality profiles.
- `printers.json`: your printers (their keys are in the Keychain).
- `refine.txt`: your usual refinements.

**Your usual refinements.** zslice notes how you refine each print after its first slice. When you made the same change in two or more other prints with the same material and nozzle, the details offer it. Click Apply (one undo step), Apply All, or × to never see it again. The records stay on your Mac.

## Quick Look

Select a G-code file in Finder and press the space bar. The preview shows the print in 3D:

- Drag to turn it, and scroll or pinch to zoom.
- The slider shows the layers up to one layer.
- Under it are the print time, the layers, the size, and the filament.
- G-code from any slicer works.

Finder shows a picture of each G-code file as its icon.

An STL file shows in the 3D viewer of macOS. A 3MF file that macOS does not show gets the zslice preview: zslice slices it with its default settings, and the slider shows its layers.

Quick Look finds the previews after the first start of zslice.app. If it does not, run `qlmanage -r`.
