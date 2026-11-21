# Labels: text and marks on a part

A label is a 2D shape on the surface of a part, in a filament of its own: text, a line, a bar, a ring, the ticks of a dial, or a free line. The slice prints it flush in the outer skin of the part, so it looks printed on. This page is for the builders of the label tool of a shell (web, Linux, Mac). The calls are in `include/zslice-app.h`, in the part "the labels of a part". The core is `src/label.zig` (the shapes and the JSON), `src/font.zig` (the font), `src/paint_split.zig` (the regions of each layer), and `src/app/labels.zig` (the calls of the app).

## What the slice does

- A side label (|normal.z| <= 0.7): on each layer, the prism of the shape along the normal of the label, cut by the plane of the layer, within the depth of the surface (one line width, 0.42 mm with a 0.4 nozzle). This region prints with the filament of the label; the rest of the layer prints with the filament of the part.
- A top or bottom label: the shape, seen along its normal, in the top layers (or the bottom layers) of the part under it: the depth in layers, at least 2.
- A stroke narrower than the narrowest line (0.34 mm with a 0.4 nozzle) goes back to the part. A gap narrower than that line fills with the label color.
- Each label slices as one more job: Arachne walls (one line for each line width of the depth), no infill, in the filament of the label.
- A label in the filament of the part, and any label on a plate with one filament, prints nothing.

## The flow of a label tool

1. Get the mesh of the part on the bed (`zs_app_part_mesh`) and make a paint session (`zs_paint_new`). The tool needs the session only for the pick; it does not paint.
2. On a click on the part, get the ray of the pointer (`zs_view_ray`) and call `zs_label_place(session, ray, radius, out)`. It gives the origin, the normal, and the right of the label (out[0..8]), and the curve of the face under it (out[9], degrees). Over 60 degrees, show "The face curves too much here; the label stretches."
3. Build the JSON of the label from the card: the frame of step 2, the filament (the next filament that is not the filament of the part), and the items. A new text label: `{"kind":"text","text":"LABEL","size":5}`.
4. `zs_app_label_add(app, part, json, len, &id)`. The id stays with the label for its life.
5. During a drag, a turn, or a key in the text field, draw the preview from `zs_label_outline(json, len, &pts, &ends, &n)`: map each point (x, y) to `origin + x * right + y * up` (up = normal x right), 0.05 mm out of the surface, in the color of the filament. The call needs no slice and no app. At the end of the drag, call `zs_app_label_update(app, part, id, json, len)` with the whole label, and start the slice as the paint tool does.
6. The card: `zs_app_label_info(app, part, id, ...)` gives the facts as JSON (see the header): the thinnest stroke, the size of text that prints clean, the changes, the minutes, and the grams, and one line of advice. After the slice, `"sliced"` is true and the changes come from the G-code.
7. Delete: `zs_app_label_remove(app, part, id)`.
8. On open, an undo, or a change of plate, read the labels again: `zs_app_part_labels_get(app, part, ...)` gives a JSON array.

## The frame

The JSON of the calls has the frame of the label in the frame of the part on the bed: the frame of `zs_app_part_mesh` and of the view. The core keeps the label in the frame of the file mesh of the part. So a move, a turn, or another side on the bed keeps the label on its face, and the next `zs_app_part_labels_get` gives the new frame.

`right` is the direction of the text (its +x axis), and up = normal x right is its +y axis. A turn of the label in its plane is a turn of `right` around `normal`: right' = right cos(a) + up sin(a). On a side face, `zs_label_place` makes `right` level (Z x normal), so the text reads from left to right in front of the face.

`stretch` is [along right, along up]. A size of a shape times the stretch is its size on the bed. A label that the API adds with no stretch keeps the sizes of its JSON on the bed; a later scale of the part stretches it with the part. Draw the preview with the stretch (zs_label_outline applies the stretch in its JSON).

## The shapes

Each item has `kind`, `at` ([x, y] mm in the plane) and `angle` (degrees). The volume dial of a speaker is one label of two items:

```json
{"origin":[30,0,12],"normal":[0,-1,0],"right":[1,0,0],"filament":2,
 "items":[{"kind":"text","text":"VOLUME","size":5,"at":[0,9]},
          {"kind":"ticks","count":11,"radius":7,"length":1.5,"length_end":3,"width":0.6}]}
```

The ticks go from 225 degrees clockwise through 270 degrees (`start`, `sweep`), and grow from `length` to `length_end`: the bars of each level around the knob.

## The sizes that print well

The font is Inter Bold (SIL Open Font License 1.1). Its stem is 0.205 of the cap height. With a line width w, text with a cap height of 2 w / 0.205 has strokes of two lines and prints clean: 4.1 mm with w = 0.42. Text of w / 0.205 (2.0 mm) has strokes of one line: it prints, but rough. The card shows these sizes (`clean_size`, `fair_size`), and a weight (up to 0.3 mm) that makes the strokes wider.

## The cost

Each layer with a side label adds about one filament change: the flush planner orders the filaments of each layer, so a layer can start with the filament that the layer under it ended with. A label 5 mm tall at 0.2 mm layers covers 25 layers: about 25 changes. A top label costs its few layers (`top_changes`). The card shows `changes`, `minutes`, and `grams` before the slice (an estimate) and after it (from the G-code). A label on the top face costs much less: say so on the card when a side label costs more than 10 changes.
