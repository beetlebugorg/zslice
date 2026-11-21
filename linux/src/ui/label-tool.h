/* label-tool.h: the Label tool (L) of the 3D view, as web/app/label.js. It
 * puts labels on the surface of a part: text, a line, a bar, a ring, the
 * ticks of a dial, or a free line, each in a filament of its own. The
 * slice prints a label flush in the outer skin of the part
 * (docs/embedding/labels.md).
 *
 * - A click on a face of a part adds a label there ("LABEL", 5 mm), in
 *   the filament after the filament of the part. A click on a label
 *   selects it, and its card opens (label-card.h).
 * - A drag of a label moves it on the surface; Shift keeps its plane. The
 *   wheel over the selected label turns it 1° a step (Shift: 15°). The
 *   handle at its corner scales it. Delete removes it; Esc closes the
 *   card, then the tool.
 * - The view keeps the beads. The core view draws each label of the part
 *   as a decal on its surface (zs_view_label_add), from its outline
 *   (zs_label_outline) with no slice, so a drag, a turn, or a key in the
 *   text field draws at once. A change goes to the core 400 ms after the
 *   last edit, or at the end of a drag, as one step of the history, and
 *   the plate slices.
 *
 * The pick uses the mesh of the part (zs_app_part_mesh) in a paint
 * session (zs_paint_new, zs_label_place). The session goes after each
 * slice, each undo, and each switch of the plate: the part can be at
 * another place then.
 *
 * view3d.c makes the tool, and sends it the clicks, the drags, the wheel,
 * and the keys. All x, y are in logical points of the 3D view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"
#include "label-model.h"

typedef struct ZgLabelTool ZgLabelTool;

/* The calls of the tool to its view: frame asks for a frame, focus gives
 * the keys back to the view, and part_at gives the part under a point (or
 * -1). */
typedef struct {
    void (*frame)(gpointer data);
    void (*focus)(gpointer data);
    gint64 (*part_at)(gpointer data, double x, double y);
    gpointer data;
} ZgLabelHost;

ZgLabelTool *zg_label_tool_new(ZgModel *model, GtkWidget *area, ZgLabelHost host);
void zg_label_tool_free(ZgLabelTool *t);
/* The core view, after the view starts. */
void zg_label_tool_set_view(ZgLabelTool *t, zs_view *view);
/* The 3D view shows (TRUE) or hides: the card and the handle show only
 * with the view. */
void zg_label_tool_set_shown(ZgLabelTool *t, gboolean shown);
/* The card and the corner handle. Add both to the overlay of the
 * preview. */
GtkWidget *zg_label_tool_card(ZgLabelTool *t);
GtkWidget *zg_label_tool_handle(ZgLabelTool *t);
/* After each frame of the view: the handle and the card follow the
 * label. */
void zg_label_tool_place(ZgLabelTool *t);

/* Opens the tool on part `part` with label `id` selected (the list of
 * the part card). */
void zg_label_tool_open(ZgLabelTool *t, gint64 part, guint32 id);

/* A press at x, y with the tool on: TRUE if it is on a label (it selects
 * it, and a drag moves it). */
gboolean zg_label_press(ZgLabelTool *t, double x, double y);
void zg_label_drag(ZgLabelTool *t, double x, double y, gboolean shift);
/* The end of a drag (also of a drag that did not start here). */
void zg_label_release(ZgLabelTool *t);
gboolean zg_label_dragging(ZgLabelTool *t);
/* A click at x, y: selects the label there, or adds a label on the face
 * of the part there, or a point of a free line that draws. */
void zg_label_click(ZgLabelTool *t, double x, double y);
/* The wheel at x, y: TRUE if it turned the selected label. */
gboolean zg_label_wheel(ZgLabelTool *t, double x, double y, double dy, gboolean shift);
/* A key with the tool on: TRUE if the tool used it (Delete, Esc). */
gboolean zg_label_key(ZgLabelTool *t, guint key);
/* The cursor name for the pointer at x, y. */
const char *zg_label_cursor(ZgLabelTool *t, double x, double y);

/* ---- for the card (label-card.c) ---- */

/* The selected label, or NULL. */
const ZgLabel *zg_label_tool_label(ZgLabelTool *t);
/* The facts of the selected label (zs_app_label_info), or NULL. */
JsonObject *zg_label_tool_info(ZgLabelTool *t);
/* The filament of the part (from 1). */
int zg_label_tool_base(ZgLabelTool *t);
/* The curve of the face under the selected label (degrees). */
double zg_label_tool_curve(ZgLabelTool *t);
/* The item that gets the points of clicks (a free line), or -1. */
int zg_label_tool_drawing(ZgLabelTool *t);
/* Selects label id (-1: none; the card closes). */
void zg_label_tool_select(ZgLabelTool *t, gint64 id);
/* The edits of the selected label. Each shows at once, and goes to the
 * core after a pause. FALSE: a bad value; the label stays. */
gboolean zg_label_tool_edit_number(ZgLabelTool *t, guint item, const char *field, double v);
gboolean zg_label_tool_edit_text(ZgLabelTool *t, guint item, const char *text);
gboolean zg_label_tool_edit_flag(ZgLabelTool *t, guint item, const char *field, gboolean on);
gboolean zg_label_tool_edit_at(ZgLabelTool *t, guint item, double x, double y);
void zg_label_tool_set_shape(ZgLabelTool *t, guint item, const char *kind);
void zg_label_tool_add_item(ZgLabelTool *t, const char *kind);
void zg_label_tool_remove_item(ZgLabelTool *t, guint item);
void zg_label_tool_set_angle(ZgLabelTool *t, double deg);
void zg_label_tool_set_filament(ZgLabelTool *t, int filament);
void zg_label_tool_add_filament(ZgLabelTool *t);
void zg_label_tool_set_depth(ZgLabelTool *t, double mm);
void zg_label_tool_remove(ZgLabelTool *t);
/* Free lines: clicks on the face add points to item i (-1: stop). */
void zg_label_tool_draw_points(ZgLabelTool *t, int item);

/* ---- copy and paste (the clipboard of view3d.c) ---- */

/* The JSON of the selected label (free it with g_free), or NULL. */
char *zg_label_tool_copy(ZgLabelTool *t);
/* Adds a copy of a label (JSON) as one step of the history, and selects
 * it; the tool opens. at_point: on the face of the part under x, y, with
 * the same turn. Else (or off the parts) on the part of the tool (or
 * `part`), under the label of the copy on the same face. TRUE for a new
 * label. */
gboolean zg_label_tool_paste(ZgLabelTool *t, const char *json, gboolean at_point, double x, double y, gint64 part);
