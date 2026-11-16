/* view3d.h: the 3D view of the toolpaths.
 *
 * Each path segment is a box: one line width wide, one layer height tall,
 * lit by a fixed light. The view shows the layers up to the layer that the
 * slider picks. Drag to orbit, scroll to zoom, and double-click to reset
 * the view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_view3d_new(ZgModel *model);

/* Reads the toolpaths of the last slice from the core again. */
void zg_view3d_reload(GtkWidget *view);

/* Shows the layers from 0 to `layer`. */
void zg_view3d_set_layer(GtkWidget *view, size_t layer);
