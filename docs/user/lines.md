# Click a line

Click any line of the print. A card says what the line is, how fast it really prints, and why.

![A click on the edge of the cabin roof: the card says Outer wall, layer 201, 76 mm/s planned, 17 mm/s real, and why: the layer is short, so it prints slower to cool](../img/line-card.webp "The card of a line: the speeds, the reason, and the settings that change the line.")

## The card of a line

Use the Select tool (V), and click a line in the 2D or the 3D view. The line turns yellow. The card shows:

- the feature and the layer, for example "Outer wall · layer 201";
- the planned speed, the real speed, and the flow;
- why the line is slow, in plain words;
- the size: the segment, the loop, and the radius of an arc;
- the settings that matter for this line, each with its field. Change one, and the part slices at once.

| Button | What it does |
|---|---|
| **Fade the others** | Shows the line solid and the other lines as faint ghosts. |
| **All settings…** | Opens the long form of the line in the panel: each number, and how it comes about. |
| **Don't print this line** | Takes the line out of the print. Delete does the same. |
| **−10 % plastic**, **+10 % plastic** | Gives the line less or more plastic. |

Esc, ×, or a click on no line closes the card. Drag the top row of the card to move it.

## Go along the print

With a line selected:

- ← and → go to the segment before or after it, in print order. Shift goes one line.
- ↑ and ↓ (or K and J) go to the nearest line on the layer above or below.
- C shows the layers up to the line. Shift+C shows all layers.
- Shift+click adds a line to the selection.

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
