/* preview.c: see preview.h.
 *
 * The view maps mm to pixels with a scale and an offset: a point (x, y) in
 * mm is at (ox + x * scale, height - (oy + y * scale)) on the screen. The y
 * axis goes up, as on the printer bed.
 *
 * The preview asks the core for the paths of one layer when the layer
 * changes. The core makes them in a few milliseconds, so the shell keeps
 * only the layer on the screen.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "preview.h"

#include <math.h>

typedef struct {
    ZgModel *model;
    GtkWidget *area;
    GtkWidget *slider;
    GtkWidget *label;
    zs_layer_paths paths;
    gboolean have_paths;
    size_t layer_count;
    double scale, ox, oy;
    double pointer_x, pointer_y;
    double drag_ox, drag_oy;
    gboolean fitted;
    gboolean updating_slider;
} Preview;

/* The colors of the features, in the order of enum zs_feature. The same
 * colors as the SVG preview of the command line tool. */
static const double feature_rgb[][3] = {
    {0.851, 0.282, 0.059}, /* outer wall: orange */
    {0.961, 0.624, 0.000}, /* inner wall: yellow */
    {0.110, 0.494, 0.839}, /* skin: blue */
    {0.169, 0.541, 0.243}, /* infill: green */
    {0.682, 0.243, 0.788}, /* ironing: purple */
};
#define N_FEATURES (sizeof feature_rgb / sizeof feature_rgb[0])

static void free_paths(Preview *p) {
    if (p->have_paths) {
        zs_layer_paths_free(&p->paths);
        p->have_paths = FALSE;
    }
}

static double setting_mm(Preview *p, const char *key, double fallback) {
    char *v = zg_model_get(p->model, key);
    char *end = NULL;
    double d = g_ascii_strtod(v, &end);
    gboolean ok = end && end != v;
    g_free(v);
    return ok ? d : fallback;
}

/* Fits the part (or the bed, with no result) in the view. */
static void fit(Preview *p) {
    int w = gtk_widget_get_width(p->area);
    int h = gtk_widget_get_height(p->area);
    if (w <= 0 || h <= 0) return;
    double b[4];
    if (zs_app_part_bounds(zg_model_core(p->model), b) != ZS_OK) {
        b[0] = 0;
        b[1] = 0;
        b[2] = setting_mm(p, "machine.bed_size_x", 220);
        b[3] = setting_mm(p, "machine.bed_size_y", 220);
    }
    double bw = fmax(b[2] - b[0], 1), bh = fmax(b[3] - b[1], 1);
    p->scale = 0.85 * fmin(w / bw, h / bh);
    p->ox = w / 2.0 - (b[0] + b[2]) / 2 * p->scale;
    p->oy = h / 2.0 - (b[1] + b[3]) / 2 * p->scale;
    p->fitted = TRUE;
}

static void load_layer(Preview *p, size_t layer) {
    free_paths(p);
    zs_app *core = zg_model_core(p->model);
    if (layer < p->layer_count && zs_app_layer_paths(core, layer, &p->paths) == ZS_OK) {
        p->have_paths = TRUE;
        char *text = g_strdup_printf("Layer %zu of %zu\nz %.2f mm", layer + 1, p->layer_count, p->paths.z);
        gtk_label_set_text(GTK_LABEL(p->label), text);
        g_free(text);
    } else {
        gtk_label_set_text(GTK_LABEL(p->label), "");
    }
    gtk_widget_queue_draw(p->area);
}

static void add_polyline(cairo_t *cr, const float *pts, uint32_t start, uint32_t end, gboolean closed) {
    if (end <= start) return;
    cairo_move_to(cr, pts[2 * start], pts[2 * start + 1]);
    for (uint32_t i = start + 1; i < end; i++) cairo_line_to(cr, pts[2 * i], pts[2 * i + 1]);
    if (closed) cairo_close_path(cr);
}

static void draw_message(cairo_t *cr, int w, int h, const char *text) {
    cairo_set_source_rgb(cr, 0.45, 0.48, 0.52);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 16);
    cairo_text_extents_t ext;
    cairo_text_extents(cr, text, &ext);
    cairo_move_to(cr, (w - ext.width) / 2, h / 2.0);
    cairo_show_text(cr, text);
}

static void draw(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    Preview *p = data;
    zs_app *core = zg_model_core(p->model);
    int state = zs_app_state(core);

    cairo_set_source_rgb(cr, 0.965, 0.969, 0.973);
    cairo_paint(cr);

    if (state == ZS_STATE_EMPTY) {
        draw_message(cr, w, h, "Open an STL file, or drop it here");
        return;
    }
    if (!p->fitted) fit(p);

    cairo_save(cr);
    cairo_translate(cr, p->ox, h - p->oy);
    cairo_scale(cr, p->scale, -p->scale);

    /* The bed, with a 10 mm grid. */
    double bx = setting_mm(p, "machine.bed_size_x", 220), by = setting_mm(p, "machine.bed_size_y", 220);
    cairo_rectangle(cr, 0, 0, bx, by);
    cairo_set_source_rgb(cr, 0.906, 0.914, 0.925);
    cairo_fill(cr);
    cairo_set_line_width(cr, 1.0 / p->scale);
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

    if (p->have_paths) {
        const zs_layer_paths *lp = &p->paths;
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
        for (size_t f = 0; f < N_FEATURES; f++) {
            for (size_t i = 0; i < lp->path_count; i++) {
                if (lp->path_features[i] != f) continue;
                uint32_t start = i == 0 ? 0 : lp->path_ends[i - 1];
                add_polyline(cr, lp->points, start, lp->path_ends[i], lp->path_closed[i]);
            }
            cairo_set_source_rgba(cr, feature_rgb[f][0], feature_rgb[f][1], feature_rgb[f][2], 0.9);
            cairo_stroke(cr);
        }
    }
    cairo_restore(cr);

    if (state == ZS_STATE_FAILED) draw_message(cr, w, h, "The slice failed. See the status bar.");
}

static void on_slider(GtkRange *range, gpointer data) {
    Preview *p = data;
    if (p->updating_slider) return;
    load_layer(p, (size_t)gtk_range_get_value(range));
}

static gboolean on_scroll(GtkEventControllerScroll *ctrl, double dx, double dy, gpointer data) {
    Preview *p = data;
    int h = gtk_widget_get_height(p->area);
    double factor = dy < 0 ? 1.2 : 1 / 1.2;
    /* Keep the point under the pointer in place. */
    double mx = (p->pointer_x - p->ox) / p->scale;
    double my = ((h - p->pointer_y) - p->oy) / p->scale;
    p->scale *= factor;
    p->ox = p->pointer_x - mx * p->scale;
    p->oy = (h - p->pointer_y) - my * p->scale;
    gtk_widget_queue_draw(p->area);
    return TRUE;
}

static void on_motion(GtkEventControllerMotion *ctrl, double x, double y, gpointer data) {
    Preview *p = data;
    p->pointer_x = x;
    p->pointer_y = y;
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    Preview *p = data;
    p->drag_ox = p->ox;
    p->drag_oy = p->oy;
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    Preview *p = data;
    p->ox = p->drag_ox + dx;
    p->oy = p->drag_oy - dy;
    gtk_widget_queue_draw(p->area);
}

static void on_double_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Preview *p = data;
    if (n != 2) return;
    fit(p);
    gtk_widget_queue_draw(p->area);
}

static void preview_free(gpointer data) {
    Preview *p = data;
    free_paths(p);
    g_object_unref(p->model);
    g_free(p);
}

GtkWidget *zg_preview_new(ZgModel *model) {
    Preview *p = g_new0(Preview, 1);
    p->model = g_object_ref(model);
    p->scale = 1;

    p->area = gtk_drawing_area_new();
    gtk_widget_set_hexpand(p->area, TRUE);
    gtk_widget_set_vexpand(p->area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(p->area), draw, p, NULL);

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), p);
    gtk_widget_add_controller(p->area, scroll);
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), p);
    gtk_widget_add_controller(p->area, motion);
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), p);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), p);
    gtk_widget_add_controller(p->area, GTK_EVENT_CONTROLLER(drag));
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_double_click), p);
    gtk_widget_add_controller(p->area, GTK_EVENT_CONTROLLER(click));

    p->slider = gtk_scale_new_with_range(GTK_ORIENTATION_VERTICAL, 0, 1, 1);
    gtk_range_set_inverted(GTK_RANGE(p->slider), TRUE);
    gtk_scale_set_digits(GTK_SCALE(p->slider), 0);
    gtk_scale_set_draw_value(GTK_SCALE(p->slider), FALSE);
    gtk_widget_set_vexpand(p->slider, TRUE);
    gtk_widget_set_sensitive(p->slider, FALSE);
    gtk_widget_set_tooltip_text(p->slider, "The layer to show. Use the arrow keys for one layer.");
    g_signal_connect(p->slider, "value-changed", G_CALLBACK(on_slider), p);

    p->label = gtk_label_new("");
    gtk_label_set_justify(GTK_LABEL(p->label), GTK_JUSTIFY_CENTER);
    gtk_widget_add_css_class(p->label, "caption");
    gtk_widget_add_css_class(p->label, "numeric");

    GtkWidget *side = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_top(side, 8);
    gtk_widget_set_margin_bottom(side, 8);
    gtk_widget_set_margin_end(side, 8);
    gtk_box_append(GTK_BOX(side), p->label);
    gtk_box_append(GTK_BOX(side), p->slider);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(box), p->area);
    gtk_box_append(GTK_BOX(box), side);
    g_object_set_data_full(G_OBJECT(box), "zg-preview", p, preview_free);
    return box;
}

void zg_preview_refresh(GtkWidget *preview) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    zs_app *core = zg_model_core(p->model);
    int state = zs_app_state(core);
    if (state == ZS_STATE_EMPTY) {
        p->fitted = FALSE;
        p->layer_count = 0;
        free_paths(p);
    }
    if (state != ZS_STATE_DONE) {
        /* Keep the old layer on the screen while a new slice runs. */
        gtk_widget_queue_draw(p->area);
        return;
    }
    size_t old_count = p->layer_count;
    size_t old_layer = (size_t)gtk_range_get_value(GTK_RANGE(p->slider));
    p->layer_count = zs_app_layer_count(core);
    if (p->layer_count == 0) return;

    /* Keep the same layer if it still exists. On the first result, show the
     * top layer. */
    size_t layer = (old_count == 0 || old_layer >= p->layer_count) ? p->layer_count - 1 : old_layer;
    p->updating_slider = TRUE;
    gtk_range_set_range(GTK_RANGE(p->slider), 0, (double)(p->layer_count > 1 ? p->layer_count - 1 : 1));
    gtk_range_set_value(GTK_RANGE(p->slider), (double)layer);
    p->updating_slider = FALSE;
    gtk_widget_set_sensitive(p->slider, p->layer_count > 1);
    if (old_count == 0) p->fitted = FALSE;
    load_layer(p, layer);
}
