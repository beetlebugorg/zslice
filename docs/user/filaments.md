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
- **A face or some letters**: use the Paint tool (P). A click paints a whole face. The brush paints where you drag.

Each change of filament is a filament change in the G-code. A printer with a unit that feeds many filaments (a Bambu Lab AMS, a Prusa MMU) changes it alone. Any other printer stops (M600), and you change the filament by hand.

## Support in its own filament

Search for **support filament**, and pick a chip:

- **Part**: the support prints with the filament of the part (the default).
- A number: the support prints with that filament. A filament that breaks away, or one that dissolves in water, makes support easy to take off.

The **support interface filament** is the filament of the layers that touch the part. **Support** means the same filament as the support.

zslice prints all the lines of one filament on a layer together. So a layer changes the filament once for each filament on it.

## Less plastic for each change

After a change, the nozzle flushes the old color out: into the chute of a Bambu Lab printer, or into the prime tower. zslice uses less plastic for this flush:

- **Flush into hidden lines.** After a change, the new filament first prints its infill and its support body on that layer. Nobody sees these lines, so the old color can go into them. The flush is less by the plastic of these lines. A change between two kinds of material (PLA and PETG) flushes into the support body only. Search for **flush into hidden** to turn it off.

## Use the filaments of the printer

For a printer of a printdeck, click **Use the filaments of** and the name of the printer. zslice reads the spools that the printer has, and makes the filaments of the plate the same: their count, material, and color. On a Bambu Lab printer, it reads the nozzles too.

## Two nozzles

The Bambu Lab X2D and H2D have two nozzles. Each filament has a nozzle: **Main** or **2nd**.

- On the X2D, the AMS feeds the main nozzle. The external spool feeds the second one.
- The second nozzle does not reach the whole bed. The Check tells you when a part on it is out of its reach.

## Where to go next

- → [Add support](support.md)
- → [Send to a printer](printers.md)
