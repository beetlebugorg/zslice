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

/* Reads the result from the core again. Call it when the state changes. */
void zg_preview_refresh(GtkWidget *preview);

/* Shows layer `layer` on top (the top knob of the layer slider goes
 * there), for example to show an island. */
void zg_preview_show_layer(GtkWidget *preview, size_t layer);
