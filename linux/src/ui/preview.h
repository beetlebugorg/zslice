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
/* Puts undo, redo, and the history button (zg_history_tools_new) in the
 * dock under the preview, between the plates and the replay. */
void zg_preview_set_history(GtkWidget *preview, GtkWidget *tools);
/* Puts the print card at the bottom right of the preview. The dock ends
 * where the card starts. A hidden card leaves the whole width to the dock. */
void zg_preview_set_card(GtkWidget *preview, GtkWidget *card);
/* The view bar (the legend of the colors) for the middle of the header
 * bar. The window adds the search to the box. */
GtkWidget *zg_preview_view_bar(GtkWidget *preview);
/* The stack of the 2D view ("2d") and the 3D view ("3d"). Its
 * visible-child-name is the view that shows. */
GtkWidget *zg_preview_stack(GtkWidget *preview);

/* Reads the result from the core again. Call it when the state changes. */
void zg_preview_refresh(GtkWidget *preview);
/* The simulated print of the slice is ready (ZS_EVENT_SIMULATED, after
 * zs_app_sim_adopt): the 3D view shows it. */
void zg_preview_simulated(GtkWidget *preview);

/* The count of the problems of the check on the Check button (0 hides
 * it): the same count as the badge of the print card. */
void zg_preview_set_check_count(GtkWidget *preview, int n);

/* Shows layer `layer` on top (the top knob of the layer slider goes
 * there), for example to show an island. */
void zg_preview_show_layer(GtkWidget *preview, size_t layer);

/* The point of the last press in the preview: the point of a pick. */
void zg_preview_pick_point(GtkWidget *preview, double *x, double *y);

/* Shows `text` at the top of the view for `ms` milliseconds. */
void zg_preview_note(GtkWidget *preview, const char *text, guint ms);

/* The 3D view of the preview (view3d.h). */
GtkWidget *zg_preview_view3d(GtkWidget *preview);

/* TRUE if the layer slider hides some layers (for "Show all layers"). */
gboolean zg_preview_is_cut(GtkWidget *preview);
