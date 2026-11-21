# Labels on a part

A label is text or a mark on the surface of a part. It prints in one of three ways:

- **Ink**: the label prints flush in the outer skin of the part, in another filament. It looks printed on. This is the default.
- **Raised**: the label stands out of the surface by its relief.
- **Cut in**: the label is cut into the surface by its relief.

A raised or cut label works with the filament of the part too. With another filament, a raised label prints in that filament, and a cut label colors the floor of the cut.

A label can be text, a line, a bar, a ring, the ticks of a dial, a free line, or an SVG picture. One label can have more than one shape. For example, "VOLUME" and the ticks around a knob are one label.

## Add a label

1. Press **L**, or click the Label tool in the tool strip.
2. Click a face of a part. A label "LABEL" goes there, 5 mm tall, and its card opens.
3. Type the text. The view shows each key at once.
4. Pick the filament of the label on the card.

A new label gets the filament after the filament of the part. A label in the filament of the part does not show. If the plate has one filament, the card has an **Add a filament** button.

The slice starts when you stop. The beads then show the label as it prints.

## Move, turn, and resize a label

The selected label has a blue frame on the surface of the part, a white square at each corner, and a round handle over it.

- **Move**: drag the label. It follows the surface, also around a curve. Hold Shift to keep it in its plane.
- **Resize**: drag a corner square. The opposite corner stays where it is, and the label keeps its shape. Hold Shift to change the width and the height on their own. Or type a size on the card.
- **Turn**: drag the round handle around the label. Hold Shift for 15° steps. The mouse wheel over the label also turns it: 1° a step, 15° with Shift. The card has the angle too (0 is level).
- **Delete**: press Delete, or click **Delete the label** on the card.

The view shows each change as you drag. The slice starts when you let go. Each change is one step of the history. Ctrl+Z undoes it.

## Smart guides

When you move or resize a label, it snaps to the things near it on the same face. A thin pink line shows each snap. A snap starts within about 6 pixels on the screen.

- **Other labels**: the edges and the center of the label line up with the edges and the centers of the other labels on the face.
- **Equal gaps**: a label next to two labels in a row snaps to the same gap.
- **Holes**: the label centers on a round hole or a square opening of the face. It also lines up with the edges of a square opening.
- **The center**: the label centers on the face, or on the part, on one axis or on both.
- **The same size**: a resize snaps to the width or the height of another label.

Hold Alt while you drag to move or resize with no snap.

## Raised and cut labels

Pick **Ink**, **Raised**, or **Cut in** on the card. **Relief** is the height of a raised label or the depth of a cut, in mm. The default is 0.6 mm.

- A raised label on a side face adds its shape to the wall of each layer, out to the relief. It follows the face, also around a curve.
- A raised label on a top face is a plateau. Its top is flat, at the relief over the highest point of the face under it.
- A cut label removes its shape from each layer, in to the relief. The floor of a cut in a top face gets top skin, so it prints smooth.
- A raised label on a bottom face prints as ink.

Small features need a relief of two lines or more to print clean: about 0.8 mm with a 0.4 mm nozzle.

## Place an SVG picture

1. Select a label, then click **Place an SVG…** on the card. Pick an SVG file.
2. Or drop an SVG file on a face of a part. A new label of the picture goes there.

The picture is 15 mm tall at first. Its **Height** is on the card, and the handles resize it. It moves, turns, and prints as ink, raised, or cut, as each label does. A picture in a new label replaces the text "LABEL".

zslice reads the filled shapes of the picture: paths, rectangles, circles, ellipses, polygons, and polylines, with their transforms and fill rules. A line, or a shape with a stroke and no fill, becomes the outline of its stroke. Text, images, gradients, and masks do not print. Convert text to paths in your drawing program before you save the SVG.

The project, the session, and a 3MF file keep the picture in the label.

Esc closes the card. Esc again closes the tool. The labels of a part are also on the card of the part (Move tool). Click one to select it.

## Add "VOLUME" and the ticks of a dial

1. Press **L**, and click the face above the knob.
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
