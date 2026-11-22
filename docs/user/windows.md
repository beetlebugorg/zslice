# The Windows app

The Windows app is a native app for Windows 10 and 11, on x64 and ARM64. It is in progress. This page describes what it does now.

## Open a model

Press **Open** or Ctrl+O and pick an STL, 3MF, STEP, or OBJ file. You can also drop a file on the window, or give a file on the command line. The app slices the model at once, and the bottom bar shows the print time, the filament, and the layers.

The app adds itself to **Open with** for these file types. To make it the default, pick it in the Windows Default Apps settings. A file that you open from Explorer goes to the open window. It opens on a new plate if the current plate has parts.

A model site can link to the app with `zslice://open?file=` and the address of the file. The app shows the file name and the site, and asks before it downloads. It takes https addresses of public sites, up to 512 MB. A link never opens a zslice project, and it never starts a print.

## Look at the slice

| Do this | To |
|---|---|
| Drag with the left button | Turn the view |
| Drag with the right mouse button | Turn the view |
| Click with two fingers on a touchpad and slide | Move the view |
| Drag with the middle button, or hold Shift and drag | Move the view |
| Scroll, or pinch on a touchpad | Zoom |

The slider at the right shows the print up to a layer. The keys K and J go one layer up or down.

## The tools

The header has the file, the search, the printer, filament, and quality, and the main menu. One bar at the bottom has the plates, the history, the replay, the print, and Export. The strip at the left has the tools. Press the key of a tool to pick it.

| Key | Tool | What it does |
|---|---|---|
| V | Select | Click a line to see what it is, its numbers, and the settings that change it. Keys h and l step along the line, and Shift-H and Shift-L step a whole line. |
| M | Move | Drag a part. The arrow keys move a selected part by 1 mm, and with Shift by 10 mm. |
| R | Turn | Click a part, then drag one of its rings. Hold Shift for steps of 5 degrees. |
| S | Support | Point at an overhang and click to put support under it. Hold Alt and click to draw an area. See [Add support](support.md). |
| G | Grab | Click a part to pick it up, move the pointer to carry it, and click to let go. It falls and rests on the plate. Hold Alt and move to turn it. |
| T | Measure | Click two points. The ends of the lines snap, and a click on a circle measures from its center. Hold Shift for no snap. |
| P | Paint | Paint filaments on a part. See [Paint](#paint). |
| E | Label | Put text or marks on a face of a part. See [Labels](#labels). |

The card of the Support tool is at the top left of the view. It has the kind of the area (**Support grid**, **Support tree**, or **Block**) and **See through the support**. With tree support, drag a dot, a ring, or a segment. The card has **Add a branch**, **Reset support**, and **Delete branch**, and it says when a rule limits an edit.

With the Select tool, a click on a support line shows that support. **Remove this support** takes a grid support away. For a tree, drag its dots, or right-click a dot for **Delete branch**.

## Search

Press `/` or click the search field to find a setting or an action. Each setting in the results has its slider, list, or switch, and the view shows the new slice. The eye of a result shows only the lines that the setting changes.

Up and Down go through the results. Left and Right change the value. Space or Enter turns a switch or runs an action. `V` turns the eye on or off. Esc closes the search.

The results under the field close at a click outside them. The buttons over the results move the search to the left rail, to the right rail, or to a card that you can drag and resize. A rail or a card stays open until you close it, and the app remembers the place.

## Filaments

The button in the top bar has a dot for each filament of the plate. Click it to see the list.

- **+ Add a filament** adds one. × removes one, and its parts and layers go to filament 1.
- Click a color to change it. The change applies when the color picker closes.
- Pick the material of each filament. A printer with two nozzles also has a nozzle for each filament.
- The grams of each filament show after the slice.

## Paint

Press **P**. The view shows the mesh of the selected part, or of the first part. Ctrl and a click paints another part. A right drag turns the view.

- **Smart select**: click a raised letter, a logo, or a face to paint it. Shift and a click add more. A click on another filament chip repaints what you selected.
- **Brush**: drag over the surface. **Size** is the radius of the brush.
- **Remove all paint**: the whole part prints with its own filament again.

Each click or stroke is one step of the history. Esc closes the tool.

## Labels

Press **E**, and click a face of a part. A label "LABEL" goes there, and its card opens. Type the text. The view shows each key at once. See [Labels on a part](labels.md) for sizes and costs.

- **Move**: drag the label. It follows the surface. Hold Shift to keep it in its plane.
- **Resize**: drag a white corner square. The opposite corner stays. Hold Shift to change the width and the height on their own.
- **Turn**: drag the round handle over the label, or turn the wheel over the label, 1° a step. Hold Shift for 15° steps.
- **Smart guides**: a move or a resize snaps to the other labels, the holes, and the centers of the face and the part. A thin pink line shows each snap. Hold Alt for no snap.
- **Delete**: press Delete, or click **Delete the label**.

The card has the shapes (text, line, bar, ring, ticks, a free line, or an SVG picture), the turn, the print mode (**Ink**, **Raised**, or **Cut in**) with its relief, the filament, the depth, and what the label costs in filament changes. Esc closes the card. Esc again closes the tool.

**Place an SVG…** on the card puts the filled shapes of an SVG file on the label. You can also drop an SVG file on a part: a new label of the picture goes there.

## See the print

Under the tools are the line colors, Gaps, and Check.

- **The line colors**: the filament, one color for each feature, or a ramp of the speed, the flow, the layer time, or the line width. The range of a ramp shows at the top of the view. **Show the print as it forms** shows the simulated plastic, which sags where nothing holds it.
- **Gaps**: the areas of the top layer that should be solid and that no line covers, in red. Click a gap for the settings that can close it, and **Try** one.
- **Check**: the things that can make the print fail. Its button shows the count of problems, and the print card says "N to check". Click a problem to go to its layer and its line.

Click the time in the bottom bar for the details of the print. Each main setting is a button that opens the search on it. The details also have the filaments, the time of the slice, a warning with its usual fix, and the changes that you made in at least two other prints, with **Apply**.

The bottom bar has the history of your changes. Hold the pointer on a step to see what changed, and change a setting right there. **History** opens the list of the steps, where ↶ undoes one change and keeps the later ones. Right-click a step to go to it or to clear the history after it.

A change shows as a fast draft first, and the exact slice follows 300 ms after your last change or at the end of a drag. A thin bar at the top of the view shows the work, and small text says what runs and how long it took. Export and upload wait for the exact slice.

The bar under the view replays the print at a speed of 1× to 100×. Its slider moves the nozzle through the top layer. B hides the bed.

## Parts

Ctrl and a click selects a part, and Shift and a click adds a part to the selection. The card of a part has its size, its filament, its scale, Duplicate, Split, Cut, Best orientation, Less support, Reset, Make N in all, To a new plate, and Remove. It also lists the labels and the paint of the part. Delete removes the selected parts.

When the plate prints one part at a time (`project.print_sequence` is `by_object`) and has two parts or more, the card shows the place of the part, for example "Prints 2 of 3". **Print earlier** and **Print later** move the part in the print order.

## Lines

The card of a line shows its planned speed, its real speed, and its flow, and the settings that matter most for it. **Fade the others** shows the line alone. **Don't print this line** and **±10 % plastic** change this line only, and the change stays through new slices.

On a printer with two nozzles, the title of the card says **main nozzle** or **2nd nozzle**, and a line of the second nozzle shows its speed limits. The printer settings have a **Second nozzle** section only on such a printer.

## Layers

With the Select tool, press on a line and drag up or down. The body of that line turns yellow, from its layer to the layer under the pointer. Shift+K and Shift+J grow a range of layers up or down from the selected line, or from the top layer. Shift+Up and Shift+Down move the bottom of the layers that show.

A card opens beside the layers. It has the filament of the layers and the settings that can change for some layers. **+ Add a setting for these layers** searches the others. A change is for these layers only and slices at once, and ↺ removes it. With a lit body, the row **This body** gives that body its own filament. Esc, ×, a click elsewhere, or another tool closes the card.

## Projects

A project is a repository with a `printdeck.yml`: its parts, each with a printer, a Cura profile, and a material. Pick **Open a project…** in the main menu or in the search. Type `owner/repo` or a github.com address for a public repository, or click **Open a folder…**.

The dialog lists the plates and the parts. Change the count of a part, or clear its box. **Open** on a plate loads all plates of the project and slices them. **Show** then goes to a plate. Each plate has a status: **To print**, **Printing**, **Printed**, or **Failed**. The Windows app never starts a print, so you set the status yourself.

The plates of a project use the machine settings of the project. Your printer profile stays as it is. When you open a model in place of the plates, the app goes back to your printer. **Close the project** keeps its plates and forgets their status. With two plates or more, the details of the print show the sums of all plates.

To read a project, the app contacts only GitHub, over https, with no login and no key. Each file can be up to 256 MB. See [printdeck projects](projects.md).

## When you come back

The app keeps your session. After a quit it opens with the same plates, the same view, and the same window size. A file that you open from the command line opens in place of the session.

The theme follows Windows unless you choose another one in **Preferences**. The menu at the top right has the plate actions, **Hide the bed**, **Keyboard shortcuts** (also the key ?), **Licenses**, and **About**.

## The menu of the view

A right click opens a menu for what is under the pointer. On a touchpad, a two-finger click that does not slide opens it too. The Menu key and Shift+F10 open it at the pointer.

On a part, the menu adds support, blocks support, makes a layer profile, and places the part. On the bed, it arranges, clears, copies, and duplicates the plate.

Ctrl+C, Ctrl+X, Ctrl+V, and Ctrl+D copy, cut, paste, and duplicate the selected parts. Ctrl+Shift+V pastes them as a new plate. C shows the layers up to the selected line, and Shift+C shows all layers.

## The 2D view

Press 2, or choose **2D view** in the main menu, to see the top layer from above. Press 2 again or 3 to go back. A drag pans the layer, the wheel or a pinch zooms it, and a double click fits it. A click selects a line. A tool other than Select goes back to the 3D view.

## Set up a printer

At the first start, the app asks for your printer. Type a part of its name, or pick a brand, then click **Next**. Check the name, the nozzle, the filament, and the size. Set the connection, and click **Add printer**.

The top bar has the setup of the plate:

- **The printer menu** switches the printer. It also has **Printer settings and G-code…**, **Manage printers…**, **Connect a printdeck…**, **Import a profile…**, and **Add a printer…**.
- **The filament menu** has a color and a material for each filament. For a printdeck printer, **Use the filaments of** reads the spools that the printer has loaded.
- **The quality menu** lists each quality with its main points. It also has **Save as profile…** and **Import a profile…**.

## Import a profile

**Import a profile…** is in the printer menu, the quality menu, and the search. Pick one of these files:

- a PrusaSlicer or OrcaSlicer `.ini`, also a config bundle
- an OrcaSlicer or Bambu Studio `.json` preset
- a 3MF project of these slicers
- a Cura `.curaprofile`

The values become changes of the settings of the active plate. They are one step of the history, so Undo reverts them. A dialog lists the values that zslice set, the values that went into the limits of their setting, and the keys that have no zslice setting.

## Calibrate

**Calibrate** in the main menu and the search has **Temperature tower**, **Retraction test**, **Flow test**, and **Pressure advance tower**. A test goes on a new plate with the filament and the printer of the active plate, and it slices. A dialog says how to read the print, and has a button for each value.

After the print, open **Calibrate**, then **Use a value of this test…**, and click the best value. The value goes on each plate. A test does not send a file to a printer. The plate of a test stays after a restart, but its list of values does not, so pick the value before you close the app. See [Calibrate the filament](calibrate.md).

## Connect a printer

| Connection | What you need |
|---|---|
| printdeck | The address. Tap **Allow** on its screen. |
| OctoPrint | The address, and **Allow** in its web page, or an API key. |
| PrusaLink | The address and its API key. |
| Moonraker (Klipper) | The address. |
| Bambu Lab (LAN mode) | The IP address, the serial number, and the access code. |

The picker finds printers on your network. **Printers** in the top bar shows a card for each printer: its state, its job, its temperatures, its roll, and its camera.

The app reads a Bambu Lab printer and sends it nothing. It shows the JPEG camera of a P1 or an A1. It does not show the H.264 camera of an X1, H2, P2S, or X2D yet.

## Send and export

The button at the right of the bottom bar is **Export G-code…**. With a printer that takes files, it is **Upload to** that printer, and its arrow has the other ways to send.

The main menu has **Save this plate as 3MF…**, **Save project (all plates)…**, **Send all plates**, and **Export all plates…**.

**The Windows app never starts a print.** It uploads the file, and you start the print on the printer.

## Compare with Cura

**Compare with Cura…** is in the main menu and the search. It opens a window with your zslice settings next to the settings of the active printer of Cura on this computer. The app reads them from `%APPDATA%\cura` and from the Cura folder in Program Files.

The list shows the settings that differ. **Show all mapped settings** shows each setting that maps to Cura. **Reload** reads the settings of Cura again. **Use** sets one Cura value in zslice. **Use all** sets each value that differs, except the names of the printer and the filament and the start and end G-code. Undo reverts these changes.

## Preferences

Press Ctrl+, or choose **Preferences** in the main menu.

**Printers** lists your printers. Select one to change its name, connection, address, and key. **Test the connection** reads the printer and shows its bed, nozzle, motion limits, and filament. For the current printer, two buttons then copy these values to the settings. **Use this printer** makes it the current printer. **+** opens the printer picker, and **Get a key** asks the printer for a key. A saved key does not show in the form. Type a new key to replace it.

**General** has the theme, the view at the start of the app, the number of slicer threads, and the folder of the settings files.

The Windows app has no USB connection yet, and it does not keep filament settings for each roll in the printer.

## Where your settings are

Your printers and profiles are in `%APPDATA%\zslice`. API keys and access codes are encrypted for your Windows account. They are never in a file in plain text.
