# The Windows app

The Windows app is a native app for Windows 10 and 11, on x64 and ARM64. It is in progress. This page describes what it does now.

## Open a model

Press **Open** or Ctrl+O and pick an STL, 3MF, STEP, or OBJ file. You can also drop a file on the window, or give a file on the command line. The app slices the model at once, and the status bar shows the layers, the print time, and the filament.

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

The strip at the left has the tools. Press the key of a tool to pick it.

| Key | Tool | What it does |
|---|---|---|
| V | Select | Click a line to see what it is, its numbers, and the settings that change it. Keys h and l step along the line, and Shift-H and Shift-L step a whole line. |
| M | Move | Drag a part. The arrow keys move a selected part by 1 mm, and with Shift by 10 mm. |
| R | Turn | Click a part, then drag one of its rings. Hold Shift for steps of 5 degrees. |
| G | Grab | Click a part to pick it up, move the pointer to carry it, and click to let go. It falls and rests on the plate. Hold Alt and move to turn it. |
| T | Measure | Click two points. The ends of the lines snap, and a click on a circle measures from its center. Hold Shift for no snap. |

Support (S), Paint (P), and Label (E) are in the strip, and do not work yet.

## See the print

Under the tools are the line colors, Gaps, and Check.

- **The line colors**: the filament, one color for each feature, or a ramp of the speed, the flow, the layer time, or the line width. The range of a ramp shows at the top of the view. **Show the print as it forms** shows the simulated plastic, which sags where nothing holds it.
- **Gaps**: the areas of the top layer that should be solid and that no line covers, in red. Click a gap for the settings that can close it, and **Try** one.
- **Check**: the things that can make the print fail. Click one to go to its layer and its line.

The bar under the view replays the print at a speed of 1× to 100×. Its slider moves the nozzle through the top layer. B hides the bed.

## Parts

Ctrl and a click selects a part, and Shift and a click adds a part to the selection. The card of a part has its size, its scale, Duplicate, Split, Cut, Best orientation, Less support, Reset, Make N in all, To a new plate, and Remove. Delete removes the selected parts.

## Lines

The card of a line shows its planned speed, its real speed, and its flow, and the settings that matter most for it. **Fade the others** shows the line alone. **Don't print this line** and **±10 % plastic** change this line only, and the change stays through new slices.

## When you come back

The app keeps your session. After a quit it opens with the same plates, the same view, and the same window size. A file that you open from the command line opens in place of the session.

The theme follows Windows. The menu at the top right has the plate actions, **Hide the bed**, **Keyboard shortcuts** (also the key ?), **Licenses**, and **About**.

## The menu of the view

A right click opens a menu for what is under the pointer. On a touchpad, a two-finger click that does not slide opens it too. The Menu key and Shift+F10 open it at the pointer.

On a part, the menu adds support, blocks support, makes a layer profile, and places the part. On the bed, it arranges, clears, copies, and duplicates the plate.

Ctrl+C, Ctrl+X, Ctrl+V, and Ctrl+D copy, cut, paste, and duplicate the selected parts. Ctrl+Shift+V pastes them as a new plate. C shows the layers up to the selected line, and Shift+C shows all layers.

## The 2D view

Press 2, or choose **2D view** in the main menu, to see the top layer from above. Press 2 again or 3 to go back. A drag pans the layer, the wheel or a pinch zooms it, and a double click fits it. A click selects a line. A tool other than Select goes back to the 3D view.
