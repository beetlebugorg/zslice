/* support-tool.h: the Support tool (U) of the 3D view, the support editor
 * (as web/app/support.js).
 *
 * - Draw: click points on the part. A point snaps to the end of the
 *   nearest line, as the measure tape does (Shift: no snap). Click the
 *   first point again, or press Enter, to close the area. Backspace
 *   removes the last point. Esc stops the area, then clears the selection.
 * - The area: support grows under all of the part in it that faces down
 *   (Support grid or Support tree), also where the support angle gives
 *   none; or no support there (Block).
 * - Edit: click an outline to select its area, and drag a point of it.
 *   The outline follows the pointer at once. The slices wait for the end
 *   of the drag (zg_model_hold), so one slice runs at the release.
 * - A card at the top left of the view: the kind, "See through the
 *   support", the point count and the z range, and Delete.
 *
 * The core keeps the areas (zs_app_support_area_*), slices with them, and
 * keeps them in the 3MF and the history. The core view draws them
 * (zs_view_support_add). While the tool is on, the picks skip the support
 * lines (zs_view_pick_skip_support), and the support lines are faint.
 *
 * view3d.c makes the tool, and sends it the clicks, the drags, and the
 * keys. All x, y are in logical points of the 3D view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

typedef struct ZgSupport ZgSupport;

/* The calls of the tool to its view: frame asks for a frame, and focus
 * sets the focus of the view again (see zg_support_see_through). */
typedef struct {
    void (*frame)(gpointer data);
    void (*focus)(gpointer data);
    gpointer data;
} ZgSupportHost;

/* A new tool for the 3D view `area`. */
ZgSupport *zg_support_new(ZgModel *model, GtkWidget *area, ZgSupportHost host);
void zg_support_free(ZgSupport *s);
/* The core view, after the view starts. */
void zg_support_set_view(ZgSupport *s, zs_view *view);
/* The 3D view shows (TRUE) or hides: the card shows only with the view. */
void zg_support_set_shown(ZgSupport *s, gboolean shown);
/* The card. Add it to the overlay of the preview. */
GtkWidget *zg_support_card(ZgSupport *s);
/* TRUE: the support lines are faint (the tool is on, and the box "See
 * through the support" is on). */
gboolean zg_support_see_through(ZgSupport *s);
/* The view loaded the plate again (zs_view_load fills the areas). */
void zg_support_loaded(ZgSupport *s);

/* A click at x, y with the tool on: on the overhang under the pointer,
 * support under it; with alt (or while an area is drawn), a point of an
 * area. */
void zg_support_click(ZgSupport *s, double x, double y, gboolean shift, gboolean alt);
/* The pointer is at x, y (no button down): the overhang under it lights
 * up. */
void zg_support_hover(ZgSupport *s, double x, double y);
/* A press at x, y: TRUE if it starts the drag of a point. */
gboolean zg_support_press(ZgSupport *s, double x, double y);
/* The pointer of the drag is at x, y. */
void zg_support_drag(ZgSupport *s, double x, double y, gboolean shift);
/* The end of a drag (also of a drag that did not start here). */
void zg_support_release(ZgSupport *s);
gboolean zg_support_dragging(ZgSupport *s);
/* A key with the tool on: TRUE if the tool used it. */
gboolean zg_support_key(ZgSupport *s, guint key);
/* The cursor name for the pointer at x, y. */
const char *zg_support_cursor(ZgSupport *s, double x, double y);
