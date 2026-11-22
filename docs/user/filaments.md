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
- **One part of a layer**: click a line, and pick a chip in the row **Filament** of its card. Only the body of that line on its layer gets the filament. The card then offers the layers above and below. See [Give a line a filament](lines.md#give-a-line-a-filament).
- **One body on some layers**: drag over the layers from a line of that body. Pick a chip in the row **This part of the layers**. Only the lit body gets the filament, and the other bodies on those layers keep theirs. The row **Whole layers** is for all the lines. See [Give a body a filament](lines.md#give-a-body-a-filament).
- **Search**: type "color", "material", "extruder", or "tool" in the search. The filament comes first.
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

## The prime tower

A printer that changes the filament by itself (an AMS, a tool changer) prints a prime tower next to the parts. The tower makes the new filament ready before it touches the part. At each change, the steps are:

1. The change. A Bambu Lab printer flushes the old color into its chute. Other printers flush into the tower in step 3.
2. On a printer with more than one nozzle, the nozzle that stops printing waits at its standby temperature (see [Standby and preheat](#standby-and-preheat)). The new nozzle gets its print temperature back after the cooling of the change.
3. The tower. The nozzle primes the new filament in rows on the tower, and wipes on it. A Bambu Lab printer primes 45 mm³ there, as Bambu Studio does.
4. The part. The hidden lines print first (see **Flush into hidden lines**), then the walls and the skin.

The tower grows on each layer up to the last change. A layer with no change prints the loop of the tower and a grid of lines on it. So the tower is always at the height of the nozzle, and the rows of the next change have a base.

On a printer with more than one nozzle, each nozzle holds its own filament. A switch to another nozzle has no color flush, and the new nozzle primes on the tower. Only a change of the filament in one nozzle flushes.

Keep the parts away from the tower. The Check tells you when the tower is on a part or off the bed. Set **prime tower x** and **prime tower y** to move it.

## Use the filaments of the printer

The plate uses the filaments that are in its printer. zslice reads the spools of a printdeck printer, and the AMS trays of a Bambu Lab printer in the GTK app. Filament 1 is the first spool, filament 2 the next spool, and so on.

- zslice sets the count, the material, the color, and the nozzle of each filament. A new material gets its built-in profile.
- zslice reads the spools again when you pick another printer, and each 20 s on the web (each 5 s in the GTK app).
- The filament button says **From the printer**. Each filament in the list shows its spool, for example **A1**.
- This works on a printer that changes the filament by itself, such as a Bambu Lab printer with an AMS. A printer that pauses for each change keeps the filaments that you add.

A filament that you change by hand stays as you set it. To make it follow the printer again, open the filament menu and click **Use the filaments of** and the name of the printer. On a Bambu Lab printer, this reads the nozzles too.

The print starts with the first filament of the plate. A plate of filament 4 only loads filament 4, so the printer needs only the tray of filament 4.

## More than one nozzle

Some printers have more than one nozzle, each with its own hot end:

- The Bambu Lab X2D and H2D have two nozzles.
- A tool changer has a tool for each nozzle: the Prusa XL 2T and 5T, the Prusa CORE One INDX 4T and 8T, and the E3D and Voron tool changers.
- An IDEX printer has two heads on one X axis.

zslice supports up to 16 nozzles. Set **Nozzles** (`machine.nozzles`) in the printer settings. The models of the printer library with a hot end for each extruder have it set.

Each filament has a nozzle. In the filament list, each filament has a nozzle choice: **Main** or **2nd** for two nozzles, or the tools **T0**, **T1**, and on for more. A filament on a nozzle that the printer does not have prints on the first nozzle, and the Check tells you.

- On the X2D, the AMS feeds the main nozzle. The external spool feeds the second one.
- A nozzle can have a limited reach. The second nozzle of the X2D does not reach the whole bed. The Check tells you when a part on a nozzle is out of its reach.
- A change to another nozzle has no color flush: each nozzle holds its own filament. Only a new filament in the same nozzle flushes.

### Tool changes

On a tool changer, the number of each tool change command is the nozzle: filament 2 on nozzle 3 prints after `T3`. **Tool numbers** (`machine.tool_numbers`) sets this. `filament` is for an AMS, an MMU, and the X2D and H2D: the number is the filament. `nozzle` is for a tool changer and an IDEX printer.

At each change to another nozzle, zslice writes these steps:

1. The old nozzle goes to its standby temperature (see below).
2. The change G-code of the printer, or `T` and the nozzle. The XL and INDX models of the printer library have the change G-code of PrusaSlicer and OrcaSlicer: it parks the old tool, waits for the temperature of the new tool, and picks it up.
3. The new nozzle waits for the temperature of its filament (`M109 T`), if the change G-code does not wait.
4. The new nozzle primes on the prime tower: it oozed while it waited.

Two filaments on one nozzle of a tool changer change with a pause (M600). You change the filament of that tool by hand.

The start G-code of the printer heats only the tools that the print uses. The variables of PrusaSlicer, such as `is_extruder_used[3]`, `first_layer_temperature[3]`, and `filament_type[initial_tool]`, have the values of the filament of each nozzle.

### Standby and preheat

A nozzle that waits for its next filament oozes. Two printer settings change its temperature:

- **Standby delta** (`machine.standby_delta`): the change of the temperature of a nozzle that waits, in °C. At -110, a nozzle that prints at 215 °C waits at 105 °C. 0 keeps its temperature. A filament with a **Standby temp** waits at that temperature. The XL models of the printer library have -110, as the print profiles of PrusaSlicer have.
- **Preheat time** (`machine.preheat_time`): the next nozzle heats to its print temperature this many seconds before its change. It is then hot at the change. zslice estimates the time of the lines before a change in the same layer.

The X2D and the H2D keep their own rule: the nozzle that stops printing waits 10 °C below its temperature, as in Bambu Studio.

### Settings of each nozzle

The printer settings have a section for each nozzle after the first: **Second nozzle (T1)**, **Third nozzle (T2)**, and on. A section shows only when the printer has that nozzle. Each setting at 0 has the value of the first nozzle.

- **Speed**: the speed of each line of the nozzle, as a part of the speed of the same line on the first nozzle. At 50 %, each line prints at half its speed. The speeds of the walls, the skin, and the infill keep their ratios.
- **Max speed**: the highest speed of a line of the nozzle, in mm/s.
- **Max accel**: the highest acceleration of a line of the nozzle.
- **Diameter** and **Line width**: the nozzle size and the line width of the walls, the skin, and the infill of the nozzle.
- **Retract length** and **Retract speed**: the retraction of the nozzle.
- **Offset x** and **Offset y**: the tool offset, when the firmware does not correct it. The G-code moves the head by minus the offset for the lines of the nozzle, as PrusaSlicer does. The XL, the INDX, the X2D, and Klipper tool changers with offsets in their config correct it: keep 0.
- **Min x**, **Max x**, and **Max height**: the reach of the nozzle.
- **Standby delta** and **Preheat time**: the standby and the preheat of this nozzle.

Travel moves keep the travel speed of the printer: the head moves the same way for each nozzle.

In a profile file, the settings of nozzle k have dotted names: `nozzle.1.max_speed = 200`. A profile from before, with `nozzle2_max_speed`, still loads: the settings of the second nozzle are those of nozzle 1 now.

The X2D profile of the printer library has the values of Bambu Studio for its second nozzle, a bowden extruder: at most 200 mm/s, an acceleration of 1000 mm/s², and a 2 mm retraction at 20 mm/s.

### Slow down the second nozzle

To print the second nozzle at 50 mm/s:

1. Open the settings, and pick **Printer** > **Second nozzle (T1)**.
2. Set **Max speed** to 50.
3. Slice again.

Click a line of the second nozzle. The line card shows **2nd nozzle** and the speed of the line. On a printer with more nozzles, it shows the tool, for example **nozzle T3**.

### Infill with another nozzle

Search for **infill filament**, and pick a filament of another nozzle. That nozzle then prints the sparse infill, at its own line width. The walls and the skin stay on the filament of the part.

With **Infill layers** at 2, the infill prints once every two layers, as one bead two layers tall. Example: layers of 0.1 mm for the walls, and the infill in beads of 0.2 mm. The other nozzle then prints the infill on every second layer: it prints after the walls of that layer, and the first nozzle starts the next layer. The narrow areas of infill that print on each layer stay on the filament of the part. A bead is never taller than the diameter of its nozzle or its line width. When the layers of the group are too thick for that, the Check tells you.

## Where to go next

- → [Add support](support.md)
- → [Send to a printer](printers.md)
