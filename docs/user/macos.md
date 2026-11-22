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

Open an STL, 3MF, STEP (.step, .stp), or OBJ file in one of these ways:

- File > Open (Command-O), or File > Open Recent.
- Drop the file on the icon of the app.

An "Open in slicer" link of a model site (`zslice://open?file=…`) opens zslice too. zslice asks first, with the name of the file and the site; Cancel is the default. After a yes it downloads the model and opens it on a new plate. A link never starts a print, and it does not open a zslice project or a file from a device on your network.

Each file opens in a window. A window can be a tab of another window (Window > Merge All Windows). File > New (Command-N) opens an empty window.

## The window

The 3D view fills the window. The controls float over it, so the slice has the room.

### The toolbar

From left to right:

- **The file button**, with the name of the document. Its menu opens files, adds models, saves, renames, and exports.
- **The search field** (`/` or Command-F): the settings and the actions. Its button at the right undocks it. While it is undocked, a Search button takes its place.
- **The printer menu**: your printers, Add a Printer, Connect a Printdeck, and Manage Printers. With a connected printer, it can also take the bed, the nozzle, the motion, or the filament that the printer reports.
- **The Filament button**: a dot in the color of each filament of the plate. See [Filaments](#filaments).
- **The Quality menu**: the built-in qualities and yours, and Save as Profile. Each built-in quality has its main points under its name, for example "0.1 mm layers · 3 walls · slower walls · ironed tops". A dot means that this print has changes on top of the quality.
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
| Support | S (or U) | Draw or remove support. |
| Grab | G | Pick a part up and carry it. |
| Measure | T | Measure between two points. |
| Paint | P | Paint filaments on a part. |
| Label | E | Put text or a mark on a part, in another filament. |

Under the tools, after a line, are the colors of the lines and the legend (a legend icon), Gaps (no key; also View > Show Gaps), and Check. Paint has the palette icon. H and L are free for the vim keys: h and l step the nozzle, or the selected line, back and on, and Shift-H and Shift-L step a whole line.

The × at the top right of a card closes it. Notes of the app show at the bottom of the view, over the bar.

### The bottom bar

The bar at the bottom has two rows:

- **The plates**: the plate menu (all plates, add a plate, remove a plate), the printer of the plate, and a new plate.
- **The history**: Undo, Redo, a bubble for each step, and History.
- **The replay**: play, the time in the top layer, and the speed.

At the right end are the time of the print, with the plastic, the cost, and the layers under it. Next to them are a badge and Export (Command-E). With a connected printer, Export is Print (Command-P), and its menu has Upload Only and Export G-code.

After a change, the view gets a quick draft of the slice first, and the exact slice follows when you stop changing for 0.3 s (or let go of a drag). While the view has a draft, Export and Print wait, and the details keep the numbers of the last exact slice. A thin bar at the top of the view shows the work that runs (the draft, the exact slice, the simulated print), with small dim text such as "Draft 161 ms · Exact 461 ms".

Click the time to open the details: the notes, the totals, your usual refinements, the main settings, and the filaments. A red badge such as "3 to check" counts the problems of the Check (a warning or worse), the same count as on the Check button of the tool strip. A red badge that says Check means another note on the print, and a blue one counts your usual refinements ("2 refinements"). The details stay shut until you click, so they never cover the part. A blue badge counts your usual refinements.

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
| Copy, Cut, Paste | Command-C, Command-X, Command-V |
| Paste the copied parts or plate as a new plate | Shift-Command-V |
| Duplicate the selected parts or label | Command-D (D for parts) |
| Export the G-code | Command-E |
| Print | Command-P |
| Search the settings and the actions | `/` or Command-F |
| The settings drawer | N or Option-Command-I |
| The 2D view of one layer, and back to 3D | 2 (or View > 2D View, Command-2) |
| The 3D view | 3 |
| Fit the part | Command-0 |
| Hide the bed, or show it again | B (or View > Hide the Bed) |
| Check | Shift-Command-K |
| The Printers page | Option-Command-P |
| The history | Command-Y |
| New plate | Option-Command-N |
| Add models to the plate | Shift-Command-I |
| Open a project folder | Shift-Command-O |
| A page of layers up or down (5 % of the print), as in vi | Control-F, Control-B (Command-F is the search) |
| Select layers: the range grows up or down, and its card opens | Shift-K, Shift-J |
| The line before or after | Shift-H, Shift-L |

### The search

The search field is always in the toolbar; a small `/` in it shows its key. Type `/`, or click in it: the results show under it at once (× closes them), and the words of a setting or an action fill them. The fields of the results line up in one column. Up and Down go through the results. Return runs an action or turns a switch on or off. Esc, or `/` again, hides the results.

The button at the right end of the field undocks the search: it becomes a card over the view, with its own field. Drag its head to move it, and its corner to resize it. It opens at the same place and size next time, and zslice keeps the choice to undock. While it is undocked, the toolbar has a Search button that opens the card. The dock button of the card puts the search back in the toolbar. The buttons in the head of the results also pin the search to the left of the view (beside the tool strip) or to the right (beside the layer slider): a rail the height of the view, with the name of each setting over its control. A click in the view closes the results under the toolbar (a drag to turn or pan keeps them). The card and the rails stay open until × or Esc.

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

- **Mirror**: Mirror X and Mirror Y on the card of a part mirror it from left to right, or from front to back, in place. Each is one step of the history.
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

When the range lights one body, the card has a row "This body" first. A filament there paints that body only, on those layers: the paint goes on the part under its lines, so it follows later changes of the walls and the layer height. The body shows in the color of the filament at once, and the plate slices again. The filament of the part takes the paint away.

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

### Copy and paste

Edit > Copy (Command-C) copies the selection. The first of these that you have selected is copied:

- the selected label of the Label tool
- the selected area of the Support tool
- the changes of the layers of an open range card
- the selected parts, with their settings, paint, labels, and support
- a selected line: its report, as Copy for AI does

Edit > Paste (Command-V) puts the copy where it fits:

- Parts: with parts selected, next to them. With no selection, at the pointer on the bed. On an empty plate, at the places of the copy.
- A label: on the face under the pointer, with the same turn. With the pointer off the part, under the label of the copy (over it at the foot of the part).
- A support area: on the part under the pointer, at the same place on that part.
- The changes of layers: on the layers of the open range card.

Cut (Command-X) copies, then removes. For layers, the changes go, and the value of the print stays. Duplicate (Command-D) copies the selected parts or label in place, and keeps the clipboard. Each paste is one step of the history. A text field keeps its own copy and paste.

The context menu has Paste Here, Copy the Part, Cut the Part, and Duplicate the Part on a part. On the bed it has Copy the Plate, Duplicate the Plate, and Paste as a New Plate (Shift-Command-V). The parts stay on the clipboard of the app, so they paste on another plate, and in another window.

### Calibration prints

File > Calibrate puts a test on a new plate: a Temperature Tower, a Retraction Test, a Flow Test (a row of cubes), or a Pressure Advance Tower. A card says how to read the print, with a button for each step: Use 215 sets the value of that step on each plate. File > Calibrate > Use a Value of This Test… opens the card again.

### Profiles of other slicers

Import a Profile… in the printer menu and in the Quality menu reads a PrusaSlicer or OrcaSlicer .ini, an OrcaSlicer or Bambu Studio .json, a 3MF project of these slicers, or a Cura .curaprofile. Its values become changes of the settings, as one step of the history. A report shows what zslice set, what went into the limits of a setting, and what it did not import.

### One part at a time

With Part > Placement > Print sequence set to one part at a time, the card of a part says where it prints ("Prints 2 of 3"), with Print Earlier and Print Later. The Check says when the head can hit a printed part.

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

The filaments also follow the printer of the plate by themselves, on a printer that changes the filament by itself (an AMS): each 10 s, and at once when the plate gets another printer. A note says what changed. The filament menu then says "From the printer", and each filament shows the holder of its spool ("A1"). A filament that you set by hand shows a hand, and it stays when the printer has other spools; Use the Filaments of the printer makes it follow again. A print on a Bambu Lab printer tells it the tray of each filament (see filaments.md).

On a printer with two nozzles (the X2D), each filament has its nozzle: Main or 2nd. The settings show a Second nozzle section (its diameter, line width, and speeds), and the card of a line says which nozzle prints it. Infill filament (Part > Filaments) prints the infill in a filament of its own. The external spool feeds the second nozzle, so Use the Filaments puts its filament there. With a printer profile of one nozzle, that spool stays out.

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

### Labels

The Label tool (E) puts text, a mark, or an SVG picture on the surface of a part, in another filament. It prints flush in the outer skin of the part (Ink), out of the surface (Raised), or cut into it (Cut in). [Labels on a part](labels.md) tells all of it; on the Mac:

- Click a face of a part: a label "LABEL" goes there, 5 mm tall, and its card opens with the text selected. Type the text.
- Drag a label to move it on the surface (Shift: in its plane). The wheel over the label turns it 1° a step (Shift: 15°); on a trackpad, each 10 points of a scroll is a step. The selected label has handles on the surface: a frame around it, a square at each corner, and a round handle over it. Drag a corner to resize the label about the opposite corner; it keeps its aspect, and Shift resizes each axis on its own. Drag the round handle around the label to turn it (Shift: steps of 15°).
- A move or a resize snaps to smart guides: the other labels on the face, its holes, and the centers of the face and of the part. Thin pink lines show them. Option moves free.
- Place an SVG… on the card puts the filled shapes of an SVG file on the label; drop an SVG file on a part to make a label of it there.
- Delete removes the selected label. Esc closes the card, and Esc again the tool.
- The card has the shapes (text, a line, a bar, a ring, the ticks of a dial, or a free line), the turn, the filament, the depth, Print (Ink, Raised, or Cut in, with the Relief in mm), and what the label costs: the thinnest stroke, the size of text that prints clean, and the filament changes, minutes, and grams that it adds.
- Each change is one step of the history. The part card lists the labels of the part; click one to select it.

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

**Plates.** Each plate has a sign on the bed just in front of it, with its number and name, its printer, and its status, or its print time and filament after a slice. The signs turn and tilt with the plates, and the parts in front hide them. The sign of the active plate has a bar in the accent color. Click a sign to make its plate the active plate. An empty active plate has an **Open a model** button on its bed.

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
