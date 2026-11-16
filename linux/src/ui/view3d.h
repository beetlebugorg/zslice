/* view3d.h: the 3D view of the toolpaths.
 *
 * Each path segment is a box: one line width wide, one layer height tall,
 * lit by a fixed light. The view shows the layers up to the layer that the
 * slider picks. Left drag to orbit, middle drag to pan, right drag to
 * turn around the vertical axis, scroll to zoom toward the pointer, and
 * double-click to reset the view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_view3d_new(ZgModel *model);

/* Reads the toolpaths of the last slice from the core again. */
void zg_view3d_reload(GtkWidget *view);

/* The colors: FALSE for the filament color (the print as it will look),
 * TRUE for one color for each feature. */
void zg_view3d_set_feature_colors(GtkWidget *view, gboolean features);

/* Replay: shows the print at t seconds after the start (see
 * zs_view_set_time). */
void zg_view3d_set_time(GtkWidget *view, double t);
/* The replay length in seconds, or 0 if the view has no data. */
double zg_view3d_duration(GtkWidget *view);
/* The layer that the nozzle prints at time t. */
size_t zg_view3d_layer_at_time(GtkWidget *view, double t);

/* Shows the layers from 0 to `layer`. */
void zg_view3d_set_layer(GtkWidget *view, size_t layer);
