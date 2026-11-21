# Click a line

Click any line of the print. A card says what the line is, how fast it really prints, and why.

![A click on the edge of the cabin roof: the card says Outer wall, layer 201, 76 mm/s planned, 17 mm/s real, and why: the layer is short, so it prints slower to cool](../img/line-card.webp "The card of a line: the speeds, the reason, and the settings that change the line.")

## The card of a line

Use the Select tool (V), and click a line in the 2D or the 3D view. The line turns yellow. The card opens in a corner of the view, away from the line, so it covers no part of the line. It stays in that corner from click to click. It moves only when the next line is under it. The card shows:

- the feature, the layer, and the z, for example "Outer wall" and "Layer 201 · z 40.30 mm";
- the speed, and the planned speed when the line is slower;
- the flow, and how much of the flow limit of the filament it uses;
- the line width and height, the time of the layer, and the fan;
- why the line is slow, in plain words: a short layer, short segments, or the flow limit;
- a warning of the check at the line, for example a bridge or an overhang, after the check has run;
- for a support line: the part line that it holds up, and how many layers up;
- the settings that matter for this line, each with its field. Change one, and the part slices at once. Click the name of a setting to show it in the panel.

| Button | What it does |
|---|---|
| **Fade the others** | Shows the line solid and the other lines as faint ghosts. |
| **All settings…** | Opens the long form of the line in the panel: each number, and how it comes about. |
| **Don't print** | Takes the line out of the print. Delete does the same. |
| **−10 % plastic**, **+10 % plastic** | Gives the line less or more plastic. |

Esc, ×, or a click on no line closes the card.

## Move and size the cards

The cards remember where you put them:

- Drag the top row of a card to move it. The next card of that kind opens there.
- Drag the lower right corner to make it larger or smaller. The size stays too.
- Double-click the top row to give the card its automatic place and size again.

A card never covers the line that you clicked. If its place is over the line, the card goes beside it for this time only. The line card, the layers card, the part card, and the search keep their places in this browser.

## Select a run

Shift+click a line: the line and its whole run turn yellow. A run is one extrusion, from one retraction to the next. Use it to see where the nozzle prints without a pause.

## Go along the print

With a line selected:

- ← and → go to the segment before or after it, in print order. Shift goes one line.
- ↑ and ↓ (or K and J) go to the nearest line on the layer above or below.
- C shows the layers up to the line. Shift+C shows all layers.

## Select layers

Use the Select tool (V). Press on a line, and drag up or down. The body of that line turns yellow, from its layer to the layer under the pointer:

- Only the part that you pressed on. The other parts on the plate stay as they are.
- Only the body joined to that line. A tube that rises from a lid lights alone, with no lid. The light stops where the shape gets much wider at once.

Shift+J and Shift+K do the same from a selected line. Release the button: a card opens beside the layers, and it covers no part of them. It shows "Layers A–B" and the settings that can change for some layers: the infill density and pattern, the walls, the speeds, the fan, and the temperature. "+ Add a setting for these layers" finds the others. A change is for these layers, on all the parts of the plate, and the part slices at once. Esc, ×, or a click elsewhere ends the selection.

A drag that starts on the bed or in the air turns the view.

## Give a body a filament

A drag from a line lights one body. The card then has the row **This body** first:

1. Pick a filament chip in **This body**.
2. The body turns the color of that filament at once. The slice follows.

Only the lit body changes. To give all the lines of these layers a filament, use the row **All of these layers**.

zslice paints the faces of the part under the lines of the body, as the Paint tool does. So the color stays when you change the walls, the layer height, or the place of the part. The color goes into the body by about 2 mm from its surface. The core of a wide body keeps the filament of the part, because nobody sees it.

To take the color away, pick the filament of the part in **This body**. Each change is one step of the history, and Ctrl+Z undoes it. The project file keeps the paint.

## Select a support

Use the Select tool (V), and click a support line:

- Tree support: the dots of that tree show. Drag a dot, its ring, or a segment to pull it, as in the Support tool. Right-click a dot for **Delete branch**.
- Grid support: the overhang that the support holds up shows in blue. Delete, or **Remove this support** on the card, removes the support there.

## The menu of the view

Right-click a line (or press Shift+F10):

- **Preview to this layer**, and **Show all layers**;
- **Add support here** and **Block support here**. See [Add support](support.md);
- **Copy for AI**: a report of the line, its settings, and its G-code, for a chat with an AI model;
- **Add a drop of plastic here**: a dot of plastic on the top layer, to fill a small gap;
- **Test print: the top layer…**: the G-code of this layer alone, to print as a test;
- **Put this side on the bed**, and **Placement**. See [Place the parts](parts.md).

Each edit of a line is one step of the history. Ctrl+Z undoes it. The project file keeps it.

## Where to go next

- → [Change a setting](change-settings.md): search, the panel, and settings for some layers.
- → [Check the print](check.md): gaps, the check list, and the measure tape.
