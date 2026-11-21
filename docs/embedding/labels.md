# Labels: text and marks on a part

A label is a 2D shape on the surface of a part, in a filament of its own: text, a line, a bar, a ring, the ticks of a dial, a free line, or an SVG picture. The slice prints it flush in the outer skin of the part (ink), out of the surface (raised), or cut into it (cut). This page is for the builders of the label tool of a shell (web, Linux, Mac). The calls are in `include/zslice-app.h`, in the part "the labels of a part". The core is `src/label.zig` (the shapes and the JSON), `src/font.zig` (the font), `src/svg_path.zig` (the SVG reader), `src/paint_split.zig` (the regions of each layer), `src/label_snap.zig` (the smart guides), and `src/app/labels.zig` (the calls of the app).

## What the slice does

- A side label (|normal.z| <= 0.7): on each layer, the prism of the shape along the normal of the label, cut by the plane of the layer, within the depth of the surface (one line width, 0.42 mm with a 0.4 nozzle). This region prints with the filament of the label; the rest of the layer prints with the filament of the part.
- A top or bottom label: the shape, seen along its normal, in the top layers (or the bottom layers) of the part under it: the depth in layers, at least 2.
- A stroke narrower than the narrowest line (0.34 mm with a 0.4 nozzle) goes back to the part. A gap narrower than that line fills with the label color.
- Each label slices as one more job: Arachne walls (one line for each line width of the depth), no infill, in the filament of the label.
- An ink label in the filament of the part, and any ink label on a plate with one filament, does not print.
- `"mode":"cut"`: the prism (or the shape in the top or bottom layers) within `relief` mm of the surface leaves the layer. The floor of a cut gets top skin. In another filament, the band of `depth` under the cut prints in that filament.
- `"mode":"raised"` on a side face: the prism out of the surface, within `relief` mm of the outline of the layer, joins the layer. On a top face, the core adds walls of the shape to the mesh, from the face to `relief` mm over its highest point: a plateau with top skin. On a bottom face, a raised label prints as ink. In another filament, the raised part prints in that filament; in the filament of the part, it is part of the part.
- Raised and cut labels change the shape, so they slice also on a plate with one filament.

## The flow of a label tool

1. Get the mesh of the part on the bed (`zs_app_part_mesh`) and make a paint session (`zs_paint_new`). The tool needs the session only for the pick; it does not paint.
2. On a click on the part, get the ray of the pointer (`zs_view_ray`) and call `zs_label_place(session, ray, radius, out)`. It gives the origin, the normal, and the right of the label (out[0..8]), and the curve of the face under it (out[9], degrees). Over 60 degrees, show "The face curves too much here; the label stretches."
3. Build the JSON of the label from the card: the frame of step 2, the filament (the next filament that is not the filament of the part), and the items. A new text label: `{"kind":"text","text":"LABEL","size":5}`.
4. `zs_app_label_add(app, part, json, len, &id)`. The id stays with the label for its life.
5. During a drag, a turn, or a key in the text field, draw the preview from `zs_label_outline(json, len, &pts, &ends, &n)`: map each point (x, y) to `origin + x * right + y * up` (up = normal x right), 0.05 mm out of the surface, in the color of the filament. The call needs no slice and no app. A shell that draws with the core view (`zs_view_draw`, as the Linux app) gives the outline and the frame to the view instead: `zs_view_labels_clear`, then `zs_view_label_add(view, frame, pts, ends, n, rgb, selected)` for each label. The view fills the paths with the depth test of the beads, so a part hides a label behind it, and it keeps the fill of an outline that did not change, so a drag costs one small upload. At the end of the drag, call `zs_app_label_update(app, part, id, json, len)` with the whole label, and start the slice as the paint tool does.
6. The card: `zs_app_label_info(app, part, id, ...)` gives the facts as JSON (see the header): the thinnest stroke, the size of text that prints clean, the changes, the minutes, and the grams, and one line of advice. After the slice, `"sliced"` is true and the changes come from the G-code.
7. Delete: `zs_app_label_remove(app, part, id)`.
8. On open, an undo, or a change of plate, read the labels again: `zs_app_part_labels_get(app, part, ...)` gives a JSON array.

## The handles and the smart guides

The tool draws its handles as decals in the plane of the selected label (with `zs_view_label_add`, or as the web app does with its own decals): a frame around the outline box, a square at each corner, and a round turn handle over the frame. Size them in pixels of the screen: the mm of one pixel at the label come from two points of the plane on the screen (`zs_view_pixel_of`). The hit test of a handle is in the plane: `zg_label_plane_hit` (GTK) and `planeHit` (web) map the pointer ray to (x, y) of the plane.

- A corner: the opposite corner of the box stays. With one scale (the default), scale the sizes of the shapes (`scaleLabel`, `zg_label_scale`); with two scales (Shift), multiply `stretch`. Then move the origin by (1 - k) times the anchor, along right and up, so the anchor stays.
- The turn handle: turn `right` around `normal`, and move the origin so the center of the box stays.
- The body: `zs_label_place` at the pointer, as before.

At the start of a drag, call `zs_label_face(session, frame, buf, cap, &len)` once (and again when the label leaves the plane). It gives the face under the label in its plane: its box, its center, the center of the part, and its holes, each `round` (with its radius), `rect` (with its sides and angle), or `other`. On each step of a move or a resize, call `zs_label_snap(json, len, buf, cap, &len)` with the box of the label after the pointer, its frame, the other labels of the part (their frames and boxes), the face, and the snap distance in mm (6 pixels). It gives the box after the snap, the move `d` (along right and up) for a move, and the guide lines to draw (`[s0, t0, s1, t1]` in the plane). With Alt, skip the snap. Clear the guides at the end of the drag.

## SVG pictures

An item `{"kind":"svg","svg":"<svg ...>...</svg>","size":15}` is the filled area of the picture, `size` mm tall, centered on its box. The reader reads the path data (all commands), rect, circle, ellipse, polygon, polyline, line, the transforms, and the fill rules. A stroke with no fill becomes an outline of the stroke. Text, images, gradients, masks, and `<use>` are not read. A picture with no area is a bad value. Read the file in the shell, and give its text in the JSON. The 3MF file, the project, and the session keep the source.

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
