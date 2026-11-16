/* layer-draw.h: the cairo drawing of one layer for the 2D preview: the
 * bed, the outline of the part, the paths in their feature colors, the
 * selected paths and segment, and the marks of a focus (the seams, the
 * travel moves, and the retractions, as in the 3D view).
 *
 * The functions draw in bed coordinates (mm, y up). The caller sets the
 * transform from mm to pixels.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <cairo.h>
#include <glib.h>

#include "zslice-app.h"

/* How to draw a layer. */
typedef struct {
    /* The selected path, as an index in the paths of the layer, or -1. */
    gint64 selected;
    /* The selected segment of the selected path, or -1. */
    gint64 segment;
    /* The focus of the settings browser (zg_model_focus): the features
     * and marks that show clearly. 0: all features show clearly. */
    guint32 focus;
    /* The focus is for the first layer only. */
    gboolean focus_first;
    /* The layer is the first layer. */
    gboolean first_layer;
    /* A line is selected, with "Fade others": all lines are faint. */
    gboolean fade_others;
    /* For each path of the layer: 1 if the travel to it retracted
     * (zs_toolpaths.path_retract), or NULL. */
    const uint8_t *retract;
    size_t retract_count;
    /* The other paths of a multiple selection (zg_model_more), as indices
     * in the toolpaths, and the paths of the layer in the toolpaths: from
     * first_path to end_path. */
    const gint64 *more;
    guint n_more;
    gint64 first_path, end_path;
} ZgLayerStyle;

/* The bed of size_x by size_y mm, with a 10 mm grid. `scale` is the pixels
 * for each mm, for a grid line of one pixel. */
void zg_draw_bed(cairo_t *cr, double size_x, double size_y, double scale);

void zg_draw_layer(cairo_t *cr, const zs_layer_paths *lp, const ZgLayerStyle *style);
