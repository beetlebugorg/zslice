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

#include <stdlib.h>
#include <string.h>

#include "../prefs/printers.h"

#include <math.h>

#include "colors.h"
#include "view3d.h"

typedef struct {
    ZgModel *model;
    GtkWidget *area;
    GtkWidget *view3d;
    GtkWidget *slider;
    GtkWidget *label;
    zs_layer_paths paths;
    gboolean have_paths;
    size_t layer_count;
    double scale, ox, oy;
    double pointer_x, pointer_y;
    double drag_ox, drag_oy;
    double press_x, press_y;
    gboolean fitted;
    gboolean updating_slider;
    /* The replay. */
    GtkWidget *stack;
    GtkWidget *slider_box;
    GtkWidget *colors;
    GtkWidget *legend;
    GtkWidget *play;
    GtkWidget *speed;
    guint tick;
    gint64 last_frame;
    double time;
} Preview;


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
        /* The time of the layer, from the move times of the G-code; a
         * mark if the layer prints slower to cool. */
        double layer_s = 0;
        gboolean slowed = FALSE;
        zs_toolpaths tp;
        if (zs_app_toolpaths(core, &tp) == ZS_OK && layer < tp.layer_count) {
            uint32_t last = tp.layer_ends[layer];
            uint32_t prev = layer > 0 ? tp.layer_ends[layer - 1] : 0;
            double t1 = last > 0 ? tp.path_end_time[last - 1] : 0;
            double t0 = prev > 0 ? tp.path_end_time[prev - 1] : 0;
            layer_s = t1 - t0;
            slowed = tp.layer_slowed[layer] != 0;
        }
        /* Only the layer number on the slider; the rest is in its tooltip. */
        char *text = g_strdup_printf("%s%zu", slowed ? "❄" : "", layer + 1);
        char *tip = g_strdup_printf("Layer %zu of %zu, at z %.2f mm. It prints in %.1f s%s. Drag, or use the arrow keys for one layer.",
                                    layer + 1, p->layer_count, p->paths.z, layer_s,
                                    slowed ? ", slower than planned, so that it cools (filament minimum layer time)" : "");
        gtk_widget_set_tooltip_text(p->slider_box, tip);
        g_free(tip);
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
        /* The selected path: a wide yellow line under the paths. */
        gint64 sel = zg_model_selected(p->model);
        zs_toolpaths tp;
        if (sel >= 0 && zs_app_toolpaths(core, &tp) == ZS_OK) {
            size_t layer = (size_t)gtk_range_get_value(GTK_RANGE(p->slider));
            uint32_t first = layer == 0 ? 0 : tp.layer_ends[layer - 1];
            if ((uint32_t)sel >= first && (uint32_t)sel < tp.layer_ends[layer]) {
                size_t i = (size_t)sel - first;
                uint32_t start = i == 0 ? 0 : lp->path_ends[i - 1];
                add_polyline(cr, lp->points, start, lp->path_ends[i], lp->path_closed[i]);
                cairo_save(cr);
                cairo_set_line_width(cr, lp->width * 2.5);
                cairo_set_source_rgba(cr, 1.0, 0.82, 0.1, 0.9);
                cairo_stroke(cr);
                cairo_restore(cr);
            }
        }
        /* The focus of the settings browser: the other features fade. */
        gboolean first_only = FALSE;
        guint32 focus = zg_model_focus(p->model, &first_only);
        size_t shown = (size_t)gtk_range_get_value(GTK_RANGE(p->slider));
        for (size_t f = 0; f < ZG_N_FEATURES; f++) {
            for (size_t i = 0; i < lp->path_count; i++) {
                if (lp->path_features[i] != f) continue;
                uint32_t start = i == 0 ? 0 : lp->path_ends[i - 1];
                add_polyline(cr, lp->points, start, lp->path_ends[i], lp->path_closed[i]);
            }
            gboolean in_focus = focus == 0 || ((focus >> f) & 1 && (!first_only || shown == 0));
            /* A selected line: the other lines are gray, so it is the
             * only color. */
            if (sel >= 0) cairo_set_source_rgba(cr, 0.70, 0.72, 0.74, 0.55);
            else cairo_set_source_rgba(cr, zg_feature_rgb[f][0], zg_feature_rgb[f][1], zg_feature_rgb[f][2], in_focus ? 0.9 : 0.12);
            cairo_stroke(cr);
        }
        /* The selected line again, on top, in its own color. */
        if (sel >= 0 && zs_app_toolpaths(core, &tp) == ZS_OK) {
            size_t layer = (size_t)gtk_range_get_value(GTK_RANGE(p->slider));
            uint32_t first = layer == 0 ? 0 : tp.layer_ends[layer - 1];
            if ((uint32_t)sel >= first && (uint32_t)sel < tp.layer_ends[layer]) {
                size_t i = (size_t)sel - first;
                uint32_t start = i == 0 ? 0 : lp->path_ends[i - 1];
                add_polyline(cr, lp->points, start, lp->path_ends[i], lp->path_closed[i]);
                cairo_set_source_rgba(cr, 1.0, 0.78, 0.05, 1.0);
                cairo_stroke(cr);
            }
        }
        /* The marks of a focus: the seams, the travel moves, and the
         * retractions (as in the 3D view). */
        if (focus & (ZS_MARK_SEAM | ZS_MARK_TRAVEL | ZS_MARK_RETRACT)) {
            zs_toolpaths all;
            gboolean have_all = zs_app_toolpaths(core, &all) == ZS_OK && shown < all.layer_count;
            size_t first_path = have_all && shown > 0 ? all.layer_ends[shown - 1] : 0;
            double px = 0, py = 0;
            gboolean have_prev = FALSE;
            for (size_t i = 0; i < lp->path_count; i++) {
                uint32_t start = i == 0 ? 0 : lp->path_ends[i - 1];
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
                if ((focus & ZS_MARK_RETRACT) && have_prev && have_all && first_path + i < all.path_count &&
                    all.path_retract[first_path + i]) {
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
    cairo_restore(cr);

    if (state == ZS_STATE_FAILED) draw_message(cr, w, h, "The slice failed. See the status bar.");
}

static const double replay_speeds[] = {1, 2, 3, 10, 30, 100};

static void stop_replay(Preview *p) {
    if (p->tick) gtk_widget_remove_tick_callback(p->view3d, p->tick);
    p->tick = 0;
    gtk_button_set_icon_name(GTK_BUTTON(p->play), "media-playback-start-symbolic");
}

static void show_time(Preview *p, size_t layer) {
    double total = zg_view3d_duration(p->view3d);
    int t = (int)p->time, d = (int)total;
    char *text = g_strdup_printf("%zu", layer + 1);
    char *tip = g_strdup_printf("Replay: %d:%02d:%02d of %d:%02d:%02d", t / 3600, t / 60 % 60, t % 60, d / 3600, d / 60 % 60, d % 60);
    gtk_widget_set_tooltip_text(p->slider_box, tip);
    g_free(tip);
    gtk_label_set_text(GTK_LABEL(p->label), text);
    g_free(text);
}

static gboolean on_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    Preview *p = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    double dt = p->last_frame ? (now - p->last_frame) / 1e6 : 0;
    p->last_frame = now;
    guint k = gtk_drop_down_get_selected(GTK_DROP_DOWN(p->speed));
    p->time += dt * replay_speeds[k < G_N_ELEMENTS(replay_speeds) ? k : 0];
    double total = zg_view3d_duration(p->view3d);
    if (p->time >= total) p->time = total;
    zg_view3d_set_time(p->view3d, p->time);
    size_t layer = zg_view3d_layer_at_time(p->view3d, p->time);
    p->updating_slider = TRUE;
    gtk_range_set_value(GTK_RANGE(p->slider), (double)layer);
    p->updating_slider = FALSE;
    show_time(p, layer);
    if (p->time >= total) {
        p->tick = 0;
        gtk_button_set_icon_name(GTK_BUTTON(p->play), "media-playback-start-symbolic");
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void on_play(GtkButton *b, gpointer data) {
    Preview *p = data;
    if (p->tick) {
        stop_replay(p);
        return;
    }
    if (zs_app_state(zg_model_core(p->model)) != ZS_STATE_DONE) return;
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
    double total = zg_view3d_duration(p->view3d);
    if (total <= 0) return;
    if (p->time >= total) p->time = 0;
    p->last_frame = 0;
    p->tick = gtk_widget_add_tick_callback(p->view3d, on_tick, p, NULL);
    gtk_button_set_icon_name(GTK_BUTTON(p->play), "media-playback-pause-symbolic");
}

static const char *legend_units[] = {"", "", "mm/s", "mm³/s", "s", "mm"};

/* The range of the ramp, beside the color menu. */
static void show_legend(Preview *p) {
    double lo = 0, hi = 0;
    guint mode = gtk_drop_down_get_selected(GTK_DROP_DOWN(p->colors));
    if (mode >= 2 && zg_view3d_legend(p->view3d, &lo, &hi)) {
        char *text = mode == 4 ? g_strdup_printf("%.0f–%.0f %s (red: short)", lo, hi, legend_units[mode])
                     : mode == 5 ? g_strdup_printf("%.2f–%.2f %s", lo, hi, legend_units[mode])
                                 : g_strdup_printf("%.0f–%.0f %s", lo, hi, legend_units[mode]);
        gtk_label_set_text(GTK_LABEL(p->legend), text);
        g_free(text);
        gtk_widget_set_visible(p->legend, TRUE);
    } else {
        gtk_widget_set_visible(p->legend, FALSE);
    }
}

static void on_color_mode(GObject *dd, GParamSpec *pspec, gpointer data) {
    Preview *p = data;
    guint mode = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    zg_view3d_set_color_mode(p->view3d, (int)mode);
    /* The next start uses the same colors. */
    char buf[8];
    g_snprintf(buf, sizeof buf, "%u", mode);
    zg_pref_set("colors", buf);
    /* A color mode is for the 3D view. */
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
    show_legend(p);
}


static void on_slider(GtkRange *range, gpointer data) {
    Preview *p = data;
    if (p->updating_slider) return;
    /* A move of the slider stops the replay, and shows whole layers. */
    stop_replay(p);
    p->time = 0;
    size_t layer = (size_t)gtk_range_get_value(range);
    load_layer(p, layer);
    zg_view3d_set_layer(p->view3d, layer);
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
    p->press_x = x;
    p->press_y = y;
    if (n != 2) return;
    fit(p);
    gtk_widget_queue_draw(p->area);
}

/* A click (a release near the press) picks the path under the pointer. */
static void on_release(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Preview *p = data;
    if (n != 1 || fabs(x - p->press_x) > 4 || fabs(y - p->press_y) > 4) return;
    zs_app *core = zg_model_core(p->model);
    if (zs_app_state(core) != ZS_STATE_DONE) return;
    int h = gtk_widget_get_height(p->area);
    double mx = (x - p->ox) / p->scale;
    double my = ((h - y) - p->oy) / p->scale;
    size_t layer = (size_t)gtk_range_get_value(GTK_RANGE(p->slider));
    size_t path = zs_app_pick_layer(core, layer, mx, my);
    zg_model_select(p->model, path == (size_t)-1 ? -1 : (gint64)path);
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    Preview *p = data;
    gtk_widget_queue_draw(p->area);
}

static void on_focus_changed(ZgModel *model, gpointer data) {
    Preview *p = data;
    gtk_widget_queue_draw(p->area);
}

static void preview_free(gpointer data) {
    Preview *p = data;
    if (p->tick) gtk_widget_remove_tick_callback(p->view3d, p->tick);
    g_signal_handlers_disconnect_by_data(p->model, p);
    free_paths(p);
    g_object_unref(p->model);
    g_free(p);
}

static void on_view_toggle(GtkToggleButton *b, gpointer data) {
    if (gtk_toggle_button_get_active(b)) gtk_stack_set_visible_child_name(GTK_STACK(data), g_object_get_data(G_OBJECT(b), "zg-page"));
}

/* The replay also turns to 3D: the buttons follow the stack. */
static void on_stack_page(GObject *stack, GParamSpec *pspec, gpointer data) {
    GtkToggleButton *b3d = data;
    gboolean is3d = strcmp(gtk_stack_get_visible_child_name(GTK_STACK(stack)), "3d") == 0;
    if (gtk_toggle_button_get_active(b3d) != is3d) {
        GtkToggleButton *other = is3d ? b3d : GTK_TOGGLE_BUTTON(gtk_widget_get_prev_sibling(GTK_WIDGET(b3d)));
        gtk_toggle_button_set_active(other, TRUE);
    }
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
    g_signal_connect(click, "released", G_CALLBACK(on_release), p);
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

    /* The 2D layer view and the 3D view, with one slider for both. */
    p->view3d = zg_view3d_new(model);
    GtkWidget *stack = gtk_stack_new();
    p->stack = stack;
    gtk_stack_add_titled(GTK_STACK(stack), p->area, "2d", "2D");
    gtk_stack_add_titled(GTK_STACK(stack), p->view3d, "3d", "3D");
    gtk_widget_set_hexpand(stack, TRUE);
    /* The first view: the preference (Preferences, General), or
     * ZSLICE_VIEW=2d or 3d for development and screenshots. */
    const char *env = g_getenv("ZSLICE_VIEW");
    char *view = env ? g_strdup(env) : zg_pref_get("view", "3d");
    if (strcmp(view, "3d") == 0) gtk_stack_set_visible_child_name(GTK_STACK(stack), "3d");
    g_free(view);
    /* 2D and 3D: two small linked buttons. */
    GtkWidget *b2d = gtk_toggle_button_new_with_label("2D");
    GtkWidget *b3d = gtk_toggle_button_new_with_label("3D");
    gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(b3d), GTK_TOGGLE_BUTTON(b2d));
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(strcmp(gtk_stack_get_visible_child_name(GTK_STACK(stack)), "3d") == 0 ? b3d : b2d), TRUE);
    g_object_set_data(G_OBJECT(b2d), "zg-page", "2d");
    g_object_set_data(G_OBJECT(b3d), "zg-page", "3d");
    g_signal_connect(b2d, "toggled", G_CALLBACK(on_view_toggle), stack);
    g_signal_connect(b3d, "toggled", G_CALLBACK(on_view_toggle), stack);
    g_signal_connect(stack, "notify::visible-child", G_CALLBACK(on_stack_page), b3d);
    GtkWidget *switcher = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(switcher, "linked");
    gtk_box_append(GTK_BOX(switcher), b2d);
    gtk_box_append(GTK_BOX(switcher), b3d);
    gtk_widget_set_tooltip_text(switcher, "2D: one layer. 3D: the layers up to the slider. In 3D: left drag to orbit, middle drag to pan, right drag to rotate freely, scroll to zoom, double-click to reset.");

    /* The controls float over the view, so the view has all the room. The
     * window is transparent (for the 3D view), so each control paints its
     * own background (the zg-float style). */
    const char *modes[] = {"Filament", "Feature", "Speed", "Flow", "Layer time", "Line width", NULL};
    GtkWidget *colors = gtk_drop_down_new_from_strings(modes);
    p->colors = colors;
    gtk_widget_set_tooltip_text(colors, "The colors of the 3D view: the filament (as the print will look), one color for each feature, or a ramp from blue (low) to red (high) of the speed, the flow, the layer time (red: short layers, which cool badly), or the line width.");
    g_signal_connect(colors, "notify::selected", G_CALLBACK(on_color_mode), p);
    p->legend = gtk_label_new("");
    gtk_widget_add_css_class(p->legend, "zg-legend");
    gtk_widget_set_visible(p->legend, FALSE);
    /* For development and screenshots: ZSLICE_COLORS=4 starts with a color
     * mode (enum zs_view_mode). */
    if (g_getenv("ZSLICE_COLORS")) {
        gtk_drop_down_set_selected(GTK_DROP_DOWN(colors), (guint)atoi(g_getenv("ZSLICE_COLORS")));
    } else {
        /* The colors of the last session. */
        char *saved = zg_pref_get("colors", "0");
        guint mode = (guint)atoi(saved);
        g_free(saved);
        if (mode > 0 && mode < 6) gtk_drop_down_set_selected(GTK_DROP_DOWN(colors), mode);
    }
    /* The replay: play and pause, and the speed. */
    p->play = gtk_button_new_from_icon_name("media-playback-start-symbolic");
    gtk_widget_set_tooltip_text(p->play, "Replay the print in the 3D view, line by line, at the speed beside it.");
    g_signal_connect(p->play, "clicked", G_CALLBACK(on_play), p);
    const char *speeds[] = {"1×", "2×", "3×", "10×", "30×", "100×", NULL};
    p->speed = gtk_drop_down_new_from_strings(speeds);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->speed), 3);
    gtk_widget_set_tooltip_text(p->speed, "The replay speed: 1x is the real print speed.");
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(bar, "zg-float");
    gtk_box_append(GTK_BOX(bar), switcher);
    gtk_box_append(GTK_BOX(bar), colors);
    gtk_box_append(GTK_BOX(bar), p->legend);
    gtk_box_append(GTK_BOX(bar), p->play);
    gtk_box_append(GTK_BOX(bar), p->speed);
    gtk_widget_set_halign(bar, GTK_ALIGN_START);
    gtk_widget_set_valign(bar, GTK_ALIGN_START);
    gtk_widget_set_margin_start(bar, 10);
    gtk_widget_set_margin_top(bar, 10);

    /* The layer slider: a thin bar on the right edge, with the layer and
     * the z (or the replay time) above it. */
    p->slider_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_add_css_class(p->slider_box, "zg-float");
    gtk_widget_add_css_class(p->slider_box, "zg-layers");
    /* The number under the bar: the knob is at the top for the top layer. */
    gtk_box_append(GTK_BOX(p->slider_box), p->slider);
    gtk_box_append(GTK_BOX(p->slider_box), p->label);
    /* A short, thin bar in the middle of the right edge. */
    gtk_widget_set_halign(p->slider_box, GTK_ALIGN_END);
    gtk_widget_set_valign(p->slider_box, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(p->slider_box, -1, 340);
    gtk_widget_set_margin_end(p->slider_box, 8);

    GtkWidget *box = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(box), stack);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), bar);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), p->slider_box);
    gtk_widget_set_size_request(stack, 200, -1);
    g_object_set_data_full(G_OBJECT(box), "zg-preview", p, preview_free);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), p);
    g_signal_connect(model, "focus-changed", G_CALLBACK(on_focus_changed), p);
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
    zg_view3d_reload(p->view3d);
    show_legend(p);
    zg_view3d_set_layer(p->view3d, layer);
}
