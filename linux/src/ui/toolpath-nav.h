/* toolpath-nav.h: the moves of the keyboard through the toolpaths of a
 * slice (zs_app_toolpaths): from segment to segment along the print, and
 * from a line to the nearest line of another layer.
 *
 * A path is an index in the toolpaths. A segment is an index in the
 * segments of a path: segment k goes from point k to point k + 1, and the
 * last segment of a closed path goes back to the first point.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

#include "zslice-app.h"

/* The layer of `path`. */
size_t zg_toolpaths_layer_of(const zs_toolpaths *tp, size_t path);

/* The number of segments of `path`: one less than its points, and one
 * more if it is closed. */
gint64 zg_toolpaths_segments(const zs_toolpaths *tp, size_t path);

/* The path on `layer` nearest to the middle point of `path`, or -1. A
 * path of another feature counts as 1 mm farther, so a path of the same
 * feature wins a near tie. */
gint64 zg_toolpaths_nearest_on_layer(const zs_toolpaths *tp, size_t path, size_t layer);

/* Moves the selection (`path`, `segment`) one step in print order: dir is
 * +1 (forward) or -1 (back). After the last segment of a path, the step
 * goes on to the next path. With `whole_line`, the step goes to the next
 * or the previous path, with no segment (-1). A path with no segment is
 * passed. Returns FALSE, and changes nothing, at the start or the end of
 * the print. A segment of -1 is no segment: the first forward step goes
 * to segment 0. */
gboolean zg_toolpaths_step(const zs_toolpaths *tp, gint64 *path, gint64 *segment, int dir, gboolean whole_line);
