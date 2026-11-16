/* toolpath-nav.c: see toolpath-nav.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "toolpath-nav.h"

#include <math.h>

size_t zg_toolpaths_layer_of(const zs_toolpaths *tp, size_t path) {
    size_t lo = 0, hi = tp->layer_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (tp->layer_ends[mid] <= path) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

gint64 zg_toolpaths_segments(const zs_toolpaths *tp, size_t path) {
    uint32_t a = path == 0 ? 0 : tp->path_ends[path - 1], b = tp->path_ends[path];
    if (b < a + 2) return 0;
    return (gint64)(b - a - 1) + (tp->path_closed[path] && b - a > 2 ? 1 : 0);
}

static double seg_dist2(double px, double py, double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay;
    double l2 = dx * dx + dy * dy;
    double t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
    t = CLAMP(t, 0, 1);
    double ex = ax + t * dx - px, ey = ay + t * dy - py;
    return ex * ex + ey * ey;
}

gint64 zg_toolpaths_nearest_on_layer(const zs_toolpaths *tp, size_t path, size_t layer) {
    uint32_t a = path == 0 ? 0 : tp->path_ends[path - 1], b = tp->path_ends[path];
    if (b <= a) return -1;
    uint32_t m = a + (b - a) / 2;
    double px = tp->points[2 * m], py = tp->points[2 * m + 1];
    uint8_t feature = tp->path_features[path];
    size_t first = layer == 0 ? 0 : tp->layer_ends[layer - 1];
    gint64 best = -1;
    double best_d = G_MAXDOUBLE;
    for (size_t i = first; i < tp->layer_ends[layer]; i++) {
        uint32_t s = i == 0 ? 0 : tp->path_ends[i - 1], e = tp->path_ends[i];
        double d = G_MAXDOUBLE;
        for (uint32_t k = s; k + 1 < e; k++)
            d = MIN(d, seg_dist2(px, py, tp->points[2 * k], tp->points[2 * k + 1], tp->points[2 * k + 2], tp->points[2 * k + 3]));
        if (e == s + 1) d = MIN(d, seg_dist2(px, py, tp->points[2 * s], tp->points[2 * s + 1], tp->points[2 * s], tp->points[2 * s + 1]));
        d = sqrt(d);
        /* Another feature counts as 1 mm farther. */
        if (tp->path_features[i] != feature) d += 1.0;
        if (d < best_d) {
            best_d = d;
            best = (gint64)i;
        }
    }
    return best;
}

gboolean zg_toolpaths_step(const zs_toolpaths *tp, gint64 *path, gint64 *segment, int dir, gboolean whole_line) {
    gint64 sel = *path, seg = *segment;
    gint64 n_segs = zg_toolpaths_segments(tp, (size_t)sel);
    gint64 p = sel;
    if (whole_line) {
        p = sel + dir;
        seg = -1;
    } else if (dir > 0) {
        seg = seg < 0 ? 0 : seg + 1;
        if (seg >= n_segs) {
            p = sel + 1;
            seg = 0;
        }
    } else {
        seg = seg < 0 ? -1 : seg - 1;
        if (seg < 0) {
            p = sel - 1;
            seg = p >= 0 ? zg_toolpaths_segments(tp, (size_t)p) - 1 : 0;
        }
    }
    /* Lines with no segment (one point) are passed. */
    while (p >= 0 && (size_t)p < tp->path_count && zg_toolpaths_segments(tp, (size_t)p) == 0) p += dir;
    if (p < 0 || (size_t)p >= tp->path_count) return FALSE;
    if (seg >= zg_toolpaths_segments(tp, (size_t)p)) seg = zg_toolpaths_segments(tp, (size_t)p) - 1;
    *path = p;
    *segment = seg;
    return TRUE;
}
