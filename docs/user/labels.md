# Labels on a part

A label is text or a mark on the surface of a part, in another filament. The label prints flush in the outer skin of the part. It looks printed on. It is not raised, and it is not cut into the part.

A label can be text, a line, a bar, a ring, the ticks of a dial, or a free line. One label can have more than one shape. For example, "VOLUME" and the ticks around a knob are one label.

## Add a label

1. Press **E**, or click the Label tool in the tool strip.
2. Click a face of a part. A label "LABEL" goes there, 5 mm tall, and its card opens.
3. Type the text. The view shows each key at once.
4. Pick the filament of the label on the card.

A new label gets the filament after the filament of the part. A label in the filament of the part does not show. If the plate has one filament, the card has an **Add a filament** button.

The slice starts when you stop. The beads then show the label as it prints.

## Move, turn, and scale a label

- **Move**: drag the label. It follows the surface, also around a curve. Hold Shift to keep it in its plane.
- **Turn**: turn the mouse wheel over the label: 1° a step. Hold Shift for 15° steps. The card has the angle too (0 is level).
- **Scale**: drag the yellow handle at the corner of the label. Or type a size on the card.
- **Delete**: press Delete, or click **Delete the label** on the card.

Each change is one step of the history. Ctrl+Z undoes it.

Esc closes the card. Esc again closes the tool. The labels of a part are also on the card of the part (Move tool). Click one to select it.

## Add "VOLUME" and the ticks of a dial

1. Press **E**, and click the face above the knob.
2. Type `VOLUME`.
3. In **+ Add a shape…**, pick **Ticks**. Ticks go under the text.
4. Set the **Offset** of the ticks so that their center is on the center of the knob. The second number moves them up or down, in mm.
5. Set the ticks:
   - **Count**: the number of ticks, for example 11.
   - **Radius**: the distance from the center to each tick. Make it larger than the knob.
   - **First length** and **Last length**: the ticks grow from the first to the last. This shows the levels.
   - **Start** and **Sweep**: the angle of the first tick, and the angle to the last one. The default is the arc of a knob: from 225° clockwise through 270°.

## Sizes that print well

The card shows the thinnest stroke of the label and the size of text that prints well. With a 0.4 mm nozzle:

- Text about 4 mm tall or larger prints clean. Each stroke is two lines wide.
- Text about 2 mm tall prints, but rough. Each stroke is one line wide.
- Smaller text loses strokes. The Check of the print lists the label.

**Weight** makes each stroke wider. It helps small text, but small holes in letters close.

**Depth** is how deep the color goes from the surface. The default is one line (about 0.4 mm). Use **2 lines** for a light filament on a dark part.

## The cost of a label

Each layer of a label adds a filament change. The card shows the changes, the minutes, and the grams of flush. Before the slice, the numbers are an estimate. After the slice, they come from the G-code.

- **A label on a side face** adds about one change for each layer that it covers. "VOLUME" 5 mm tall at 0.2 mm layers covers 26 layers: 26 changes, about 17 minutes.
- **A label on the top face** prints in the top layers only: about 3 changes.

So put a label on the top face where you can. The card says so when a side label adds more than 10 changes.
