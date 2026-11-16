/* layer-draw.c: see layer-draw.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "layer-draw.h"

#include "colors.h"

static void add_polyline(cairo_t *cr, const float *pts, uint32_t start, uint32_t end, gboolean closed) {
    if (end <= start) return;
    cairo_move_to(cr, pts[2 * start], pts[2 * start + 1]);
    for (uint32_t i = start + 1; i < end; i++) cairo_line_to(cr, pts[2 * i], pts[2 * i + 1]);
    if (closed) cairo_close_path(cr);
}

/* The index in `points` of the first point of path i. */
static uint32_t path_start(const zs_layer_paths *lp, size_t i) {
    return i == 0 ? 0 : lp->path_ends[i - 1];
}

static void add_path(cairo_t *cr, const zs_layer_paths *lp, size_t i) {
    add_polyline(cr, lp->points, path_start(lp, i), lp->path_ends[i], lp->path_closed[i]);
}

void zg_draw_bed(cairo_t *cr, double size_x, double size_y, double scale) {
    double bx = size_x, by = size_y;
    cairo_rectangle(cr, 0, 0, bx, by);
    cairo_set_source_rgb(cr, 0.906, 0.914, 0.925);
    cairo_fill(cr);
    cairo_set_line_width(cr, 1.0 / scale);
    cairo_set_source_rgb(cr, 0.82, 0.84, 0.86);
    for (double x = 0; x <= bx; x += 10) {
        cairo_move_to(cr, x, 0);
        cairo_line_to(cr, x, by);
    }
    for (double y = 0; y <= by; y += 10) {
        cairo_move_to(cr, 0, y);
        cairo_line_to(cr, bx, y);
    }
    cairo_stroke(cr);
}

void zg_draw_layer(cairo_t *cr, const zs_layer_paths *lp, const ZgLayerStyle *style) {
    /* The outline. Outer loops are counterclockwise and holes are
     * clockwise, so the winding rule fills the material only. */
    for (size_t i = 0; i < lp->outline_count; i++) {
        uint32_t start = i == 0 ? 0 : lp->outline_ends[i - 1];
        add_polyline(cr, lp->outline_points, start, lp->outline_ends[i], TRUE);
    }
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
    cairo_set_source_rgb(cr, 0.80, 0.83, 0.86);
    cairo_fill(cr);

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_width(cr, lp->width);
    /* The selected path: a wide yellow line under the paths. */
    gint64 sel = style->selected;
    if (sel >= 0) {
        add_path(cr, lp, (size_t)sel);
        cairo_save(cr);
        cairo_set_line_width(cr, lp->width * 2.5);
        cairo_set_source_rgba(cr, 1.0, 0.82, 0.1, 0.9);
        cairo_stroke(cr);
        cairo_restore(cr);
    }
    /* The focus of the settings browser: the other features fade. */
    guint32 focus = style->focus;
    for (size_t f = 0; f < ZG_N_FEATURES; f++) {
        for (size_t i = 0; i < lp->path_count; i++) {
            if (lp->path_features[i] == f) add_path(cr, lp, i);
        }
        gboolean in_focus = focus == 0 || ((focus >> f) & 1 && (!style->focus_first || style->first_layer));
        /* A selected line with "Fade others": the other lines are
         * faint. Else they keep their colors. */
        if (style->fade_others) cairo_set_source_rgba(cr, zg_feature_rgb[f][0], zg_feature_rgb[f][1], zg_feature_rgb[f][2], 0.12);
        else cairo_set_source_rgba(cr, zg_feature_rgb[f][0], zg_feature_rgb[f][1], zg_feature_rgb[f][2], in_focus ? 0.9 : 0.12);
        cairo_stroke(cr);
    }
    /* The other lines of a multiple selection on this layer: yellow. */
    if (style->n_more > 0) {
        for (guint k = 0; k < style->n_more; k++) {
            gint64 m = style->more[k];
            if (m >= style->first_path && m < style->end_path) add_path(cr, lp, (size_t)(m - style->first_path));
        }
        cairo_set_source_rgba(cr, 1.0, 0.78, 0.05, 1.0);
        cairo_stroke(cr);
    }
    /* The selected line again, on top, in its own color. */
    if (sel >= 0) {
        add_path(cr, lp, (size_t)sel);
        cairo_set_source_rgba(cr, 1.0, 0.78, 0.05, 1.0);
        cairo_stroke(cr);
        /* The selected segment: orange, a little wider. */
        gint64 seg = style->segment;
        uint32_t start = path_start(lp, (size_t)sel);
        uint32_t end = lp->path_ends[sel];
        if (seg >= 0 && end > start + 1) {
            uint32_t a = start + (uint32_t)seg;
            uint32_t b = a + 1 < end ? a + 1 : start;
            if (a < end) {
                double lw = cairo_get_line_width(cr);
                cairo_set_line_width(cr, lw * 1.6);
                cairo_move_to(cr, lp->points[2 * a], lp->points[2 * a + 1]);
                cairo_line_to(cr, lp->points[2 * b], lp->points[2 * b + 1]);
                cairo_set_source_rgba(cr, 1.0, 0.35, 0.0, 1.0);
                cairo_stroke(cr);
                cairo_set_line_width(cr, lw);
            }
        }
    }
    /* The marks of a focus: the seams, the travel moves, and the
     * retractions (as in the 3D view). */
    if (focus & (ZS_MARK_SEAM | ZS_MARK_TRAVEL | ZS_MARK_RETRACT)) {
        double px = 0, py = 0;
        gboolean have_prev = FALSE;
        for (size_t i = 0; i < lp->path_count; i++) {
            uint32_t start = path_start(lp, i);
            uint32_t end = lp->path_ends[i];
            if (end == start) continue;
            double x0 = lp->points[2 * start], y0 = lp->points[2 * start + 1];
            gboolean closed = lp->path_closed[i] && end - start > 2;
            if ((focus & ZS_MARK_TRAVEL) && have_prev) {
                cairo_save(cr);
                double dash = 0.6;
                cairo_set_dash(cr, &dash, 1, 0);
                cairo_set_line_width(cr, lp->width * 0.35);
                cairo_move_to(cr, px, py);
                cairo_line_to(cr, x0, y0);
                cairo_set_source_rgba(cr, zg_mark_rgb[1][0], zg_mark_rgb[1][1], zg_mark_rgb[1][2], 0.9);
                cairo_stroke(cr);
                cairo_restore(cr);
            }
            if ((focus & ZS_MARK_RETRACT) && have_prev && style->retract && i < style->retract_count && style->retract[i]) {
                cairo_arc(cr, px, py, lp->width * 0.9, 0, 2 * G_PI);
                cairo_set_source_rgba(cr, zg_mark_rgb[2][0], zg_mark_rgb[2][1], zg_mark_rgb[2][2], 0.95);
                cairo_fill(cr);
            }
            if ((focus & ZS_MARK_SEAM) && closed && lp->path_features[i] == ZS_FEATURE_OUTER_WALL) {
                cairo_arc(cr, x0, y0, lp->width * 1.1, 0, 2 * G_PI);
                cairo_set_source_rgba(cr, zg_mark_rgb[0][0], zg_mark_rgb[0][1], zg_mark_rgb[0][2], 0.95);
                cairo_fill(cr);
            }
            uint32_t last = closed ? start : end - 1;
            px = lp->points[2 * last];
            py = lp->points[2 * last + 1];
            have_prev = TRUE;
        }
    }
}
