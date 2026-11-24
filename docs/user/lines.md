# Click a line

Click any line of the print. A card says what the line is and how fast it really prints. **All settings…** says why.

![A click on the edge of the cabin roof: the card says Outer wall, layer 201, 76 mm/s planned, 17 mm/s real, and why: the layer is short, so it prints slower to cool](../img/line-card.webp "The card of a line: the speeds, the reason, and the settings that change the line.")

## The card of a line

Use the Select tool (V), and click a line in the 2D or the 3D view. The line turns yellow. The card opens in a corner of the view, away from the line, so it covers no part of the line. It stays in that corner from click to click. It moves only when the next line is under it. The card shows:

- the feature, the layer, and the z, for example "Outer wall" and "Layer 201 · z 40.30 mm";
- the speed, and the planned speed when the line is slower;
- the flow, and how much of the flow limit of the filament it uses;
- the line width and height, the time of the layer, and the fan;
- a warning of the check at the line, for example a bridge or an overhang, after the check has run;
- for a support line: the part line that it holds up, and how many layers up;
- the **Filament** row: a chip gives this part of the layer its own filament (see [Give a line a filament](#give-a-line-a-filament));
- the settings that matter for this line, each with its field. Change one, and the part slices at once. Click the name of a setting to show it in the panel.

| Button | What it does |
|---|---|
| **Fade the others** | Shows the line solid and the other lines as faint ghosts. |
| **All settings…** | Opens the long form of the line in the panel. **How these values come about**, at its foot, gives the reason for each number, why the line is slow (a short layer, short segments, or the flow limit), and why each setting of the card matters. |
| **Don't print** | Takes the line out of the print. Delete does the same. |
| **−10 % plastic**, **+10 % plastic** | Gives the line less or more plastic. |

Esc, ×, or a click on no line closes the card.

## Give a line a filament

The line card has the row **Filament**. It is for this part of the layer only: the line and the lines joined to it on its layer. An inner line also takes the outer wall around it.

1. Click a line.
2. Pick a filament chip in **Filament**. Pick **+** to add a filament to the plate.
3. That part of the layer turns the color of the filament at once. The slice follows.
4. The card then shows **Also the layers above** and **Also the layers below** when the body goes on there. Click one to give those layers the same filament.

The other parts of the layer keep their filament. Only the lines of that part on that layer change, as in [Give a body a filament](#give-a-body-a-filament). Each change is one step of the history, and Ctrl+Z undoes it.

## Where the card shows

In the web app, the card of a selection is a page of the **Inspector**, the column beside the view. It never covers the view, and a selection does not move or resize the view. Press N to show or hide the column. In a narrow window, the column is a row under the view. It opens only when you click the panel button in the header. A dot on that button shows that a selection has a page.

In the other apps, the card still opens over the view until they get the Inspector. Drag its top row to move it, and drag its lower right corner to change its size.

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

Shift+J and Shift+K do the same from a selected line. Release the button: the card of the layers opens. It shows "Layers A–B" and the settings that can change for some layers: the infill density and pattern, the walls, the speeds, the fan, and the temperature. "+ Add a setting for these layers" finds the others. A change is for these layers, on all the parts of the plate, and the part slices at once. Esc, ×, or a click elsewhere ends the selection.

A drag that starts on the bed or in the air turns the view.

## Give a body a filament

A drag from a line lights one body. Shift+J and Shift+K from a selected line do the same. The card then has two filament rows:

- **This part of the layers**: only the lit body.
- **Whole layers**: all the lines of these layers.

1. Pick a filament chip in **This part of the layers**.
2. The body turns the color of that filament at once. The slice follows.

zslice changes the filament of the walls, skin, and infill of the body on these layers. The lines keep their shape, and no other layer changes. The pick stays when you slice again, and it moves and turns with the part.

To take the color away, pick the filament of the part in **This part of the layers**. Each change is one step of the history, and Ctrl+Z undoes it. The project file keeps the pick. A project from an older version keeps its paint.

## Change a setting for one body

With a lit body, each row of the card has a switch:

- **This part**: the change is for the lit body only. This is the default.
- **Whole layers**: the change is for all the lines of these layers.

A change for this part makes a region of the part. The region is a modifier volume: it follows the body on each of its layers. The view shows its outline as thin purple rings. The history, Ctrl+Z, and the project file keep it. The region goes when it has no change left.

A region keeps the walls and the skin of the part. It changes the infill inside the walls. These settings can be different in a region:

- the filament (see above);
- the infill density, pattern, angle, angles, and stacking;
- the infill flow and the infill speed;
- the infill acceleration.

The other settings are for the whole layers only. Their rows say why. For example:

- The plate has one layer height at each layer.
- The fan runs at one speed for the whole layer.
- The nozzle has one temperature for the whole layer.
- The walls of the part go around the whole layer.
- The travel moves and the retractions are for the whole layer.

"+ Add a setting for these layers" uses the same rule. A setting that a region can have goes to this part. The others go to the whole layers. A search for the filament ("color", "material", "tool") shows both chips: this part of the layers, and the whole layers.

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
