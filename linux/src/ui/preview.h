/* preview.h: the 2D layer preview.
 *
 * A drawing area that shows the paths of one layer, and a vertical slider
 * that picks the layer. Scroll to zoom, and drag to pan.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* Returns the preview widget (the area and the slider in one box). */
GtkWidget *zg_preview_new(ZgModel *model);
/* Puts the timeline of the history (zg_timeline_new) in the dock at the
 * bottom of the preview, after the plates and the replay. */
void zg_preview_set_timeline(GtkWidget *preview, GtkWidget *timeline);
/* Puts the print card at the bottom right of the preview. The dock ends
 * where the card starts. A hidden card leaves the whole width to the dock. */
void zg_preview_set_card(GtkWidget *preview, GtkWidget *card);
/* The view buttons (2D and 3D, the colors) for the middle of the header
 * bar. The window adds its own buttons to the box. */
GtkWidget *zg_preview_view_bar(GtkWidget *preview);

/* Reads the result from the core again. Call it when the state changes. */
void zg_preview_refresh(GtkWidget *preview);

/* Shows layer `layer` on top (the top knob of the layer slider goes
 * there), for example to show an island. */
void zg_preview_show_layer(GtkWidget *preview, size_t layer);

/* The point of the last press in the preview: the point of a pick. */
void zg_preview_pick_point(GtkWidget *preview, double *x, double *y);

/* The 3D view of the preview (view3d.h). */
GtkWidget *zg_preview_view3d(GtkWidget *preview);

/* TRUE if the layer slider hides some layers (for "Show all layers"). */
gboolean zg_preview_is_cut(GtkWidget *preview);
