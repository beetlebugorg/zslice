# Print in colors

A plate can print with more than one filament. Each filament has a color, a material, and on some printers a nozzle.

## The filaments of the plate

Click the Filament button in the top bar. It shows a dot for each filament.

- **+ Add a filament** adds one. × removes one. Its parts and layers go to filament 1.
- Click a color to change it.
- Pick the material of each one: PLA, PETG, ABS, and others.
- The grams of each filament show after the slice.

## Give a part or layers a filament

- **A part**: select it, and pick a filament chip on its card.
- **Some layers**: drag over the layers (see [Click a line](lines.md)), and pick a filament chip on the card of the layers.
- **One body on some layers**: drag over the layers from a line of that body. Pick a chip in the row **This body**. Only the lit body gets the filament, and the other bodies on those layers keep theirs. See [Give a body a filament](lines.md#give-a-body-a-filament).
- **A face or some letters**: use the Paint tool (P). A click paints a whole face. The brush paints where you drag.
- **Text or marks on a face**: use the Label tool (E). See [Labels on a part](labels.md).

Each change of filament is a filament change in the G-code. A printer with a unit that feeds many filaments (a Bambu Lab AMS, a Prusa MMU) changes it alone. Any other printer pauses (M600, or PAUSE with Klipper). You change the filament by hand.

## Painted features hold to the part

A painted feature that stands on the part, for example a raised frame or a raised letter, can break off. So zslice grows the feature down into the part as a root:

- The root goes 1 mm into the part under the feature. Search for **paint anchor depth** to change the depth. 0 turns the root off.
- The root stays inside the walls of the part. The outside of the part keeps its color.
- The root replaces the infill of the part under the feature. Nobody sees it.
- A feature on the bed gets no root. The part of a feature over air gets no root.
- **Paint anchor shape**: **Footprint** fills all the area under the feature. **Core** fills only the middle. A thin feature gets no core.

Each layer of the root can add a filament change. A 1 mm root on 0.2 mm layers adds up to 5 changes. A layer that already has both filaments gets no new change. After a change, the nozzle prints the root first, and the root gets a part of the flush. To see the root, look at the layers under the feature.

## Support in its own filament

Search for **support filament**, and pick a chip:

- **Part**: the support prints with the filament of the part (the default).
- A number: the support prints with that filament. A filament that breaks away, or one that dissolves in water, makes support easy to take off.

The **support interface filament** is the filament of the layers that touch the part. **Support** means the same filament as the support.

zslice prints all the lines of one filament on a layer together. So a layer changes the filament once for each filament on it.

## Less plastic for each change

After a change, the nozzle flushes the old color out: into the chute of a Bambu Lab printer, or into the prime tower. zslice uses less plastic for this flush:

- **Flush into hidden lines.** After a change, the new filament first prints its infill and its support body on that layer. Nobody sees these lines, so the old color can go into them. The flush is less by the plastic of these lines. A change between two kinds of material (PLA and PETG) flushes into the support body only. Search for **flush into hidden** to turn it off.
- **The best order on each layer.** A change from a dark color to a light color flushes the most. On each layer, zslice tries each order of its filaments (up to 8) and picks the one with the least flush, after the hidden lines take their part. For black, red, and white, it prints black, then red, then white. It counts the time of each change too, so it never adds a change to save a little plastic.

## Use the filaments of the printer

The plate uses the filaments that are in its printer. zslice reads the spools of a printdeck printer, and the AMS trays of a Bambu Lab printer in the GTK app. Filament 1 is the first spool, filament 2 the next spool, and so on.

- zslice sets the count, the material, the color, and the nozzle of each filament. A new material gets its built-in profile.
- zslice reads the spools again when you pick another printer, and each 20 s on the web (each 5 s in the GTK app).
- The filament button says **From the printer**. Each filament in the list shows its spool, for example **A1**.
- This works on a printer that changes the filament by itself, such as a Bambu Lab printer with an AMS. A printer that pauses for each change keeps the filaments that you add.

A filament that you change by hand stays as you set it. To make it follow the printer again, open the filament menu and click **Use the filaments of** and the name of the printer. On a Bambu Lab printer, this reads the nozzles too.

The print starts with the first filament of the plate. A plate of filament 4 only loads filament 4, so the printer needs only the tray of filament 4.

## Two nozzles

The Bambu Lab X2D and H2D have two nozzles. Each filament has a nozzle: **Main** or **2nd**.

- On the X2D, the AMS feeds the main nozzle. The external spool feeds the second one.
- The second nozzle does not reach the whole bed. The Check tells you when a part on it is out of its reach.

### Settings of the second nozzle

The printer settings have a **Second nozzle** section. It shows only for a printer with two nozzles. Each setting at 0 has the value of the first nozzle.

- **Nozzle2 speed**: the speed of each line of the second nozzle, as a part of the speed of the same line on the first nozzle. At 50 %, each line prints at half its speed. The speeds of the walls, the skin, and the infill keep their ratios.
- **Nozzle2 max speed**: the highest speed of a line of the second nozzle, in mm/s.
- **Nozzle2 max accel**: the highest acceleration of a line of the second nozzle.
- **Nozzle2 diameter** and **Nozzle2 line width**: the nozzle size and the line width of the walls, the skin, and the infill of the second nozzle.
- **Nozzle2 retract length** and **Nozzle2 retract speed**: the retraction of the second nozzle.

Travel moves keep the travel speed of the printer: one head moves both nozzles.

The X2D profile of the printer library has the values of Bambu Studio for its second nozzle, a bowden extruder: at most 200 mm/s, an acceleration of 1000 mm/s², and a 2 mm retraction at 20 mm/s.

### Slow down the second nozzle

To print the second nozzle at 50 mm/s:

1. Open the settings, and pick **Printer** > **Second nozzle**.
2. Set **Nozzle2 max speed** to 50.
3. Slice again.

Click a line of the second nozzle. The line card shows **2nd nozzle** and the speed of the line.

### Infill with the second nozzle

Search for **infill filament**, and pick a filament of the second nozzle. The second nozzle then prints the sparse infill, at its own line width. The walls and the skin stay on the filament of the part.

With **Infill layers** at 2, the infill prints once every two layers, as one bead two layers tall. Example: layers of 0.1 mm for the walls, and the infill in beads of 0.2 mm. The second nozzle then prints the infill on every second layer: it prints after the walls of that layer, and the first nozzle starts the next layer. The narrow areas of infill that print on each layer stay on the filament of the part. A bead is never taller than the diameter of its nozzle or its line width. When the layers of the group are too thick for that, the Check tells you.

When each nozzle has only one filament of the plate, a change of the nozzle flushes no plastic. The prime tower gets a small prime.

## Where to go next

- → [Add support](support.md)
- → [Send to a printer](printers.md)
