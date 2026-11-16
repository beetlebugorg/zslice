/* view3d.h: the 3D view of the toolpaths.
 *
 * Each path segment is a box: one line width wide, one layer height tall,
 * lit by a fixed light. The view shows the layers up to the layer that the
 * slider picks. Left drag to orbit, middle drag to pan, right drag to
 * rotate freely, scroll to zoom toward the pointer, and double-click to
 * reset the view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_view3d_new(ZgModel *model);

/* Reads the toolpaths of the last slice from the core again. */
void zg_view3d_reload(GtkWidget *view);

/* The colors: enum zs_view_mode (the filament color, the features, or a
 * ramp of the speed, the flow, the layer time, or the line width). */
void zg_view3d_set_color_mode(GtkWidget *view, int mode);
/* The range of the ramp of a value mode (see zs_view_legend). */
gboolean zg_view3d_legend(GtkWidget *view, double *min, double *max);

/* Replay: shows the print at t seconds after the start (see
 * zs_view_set_time). */
void zg_view3d_set_time(GtkWidget *view, double t);
/* The replay length in seconds, or 0 if the view has no data. */
double zg_view3d_duration(GtkWidget *view);
/* The layer that the nozzle prints at time t. */
size_t zg_view3d_layer_at_time(GtkWidget *view, double t);

/* Shows the layers from 0 to `layer`. */
void zg_view3d_set_layer(GtkWidget *view, size_t layer);
/* Shows the layers from lo to hi. */
void zg_view3d_set_layer_range(GtkWidget *view, size_t lo, size_t hi);
