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
#include <stdlib.h>
#include <string.h>

#include "../prefs/printers.h"
#include "layer-draw.h"
#include "layer-range.h"
#include "toolpath-nav.h"
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
    /* The replay. */
    GtkWidget *stack;
    GtkWidget *slider_box;
    GtkWidget *isolate;
    /* The plates: a button for each, and "+". */
    GtkWidget *plates;
    /* The scrub bar: the nozzle through the top layer (0 its start, 1 the
     * layer done), and its time label. */
    GtkWidget *scrub, *scrub_label, *scrub_box;
    gboolean scrub_quiet;
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
        size_t lo = zg_layer_range_get_lo(ZG_LAYER_RANGE(p->slider));
        char *text = lo > 0 && lo < layer ? g_strdup_printf("%zu\n%s%zu", layer + 1, slowed ? "❄" : "", lo + 1)
                                          : g_strdup_printf("%s%zu", slowed ? "❄" : "", layer + 1);
        char *tip = g_strdup_printf("Layer %zu of %zu, at z %.2f mm. It prints in %.1f s%s. Drag a knob: the top knob is the top layer, and the bottom knob the lowest layer that shows. Arrow keys: the top knob; Shift+arrow keys: the bottom knob.",
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

    zg_draw_bed(cr, setting_mm(p, "machine.bed_size_x", 220), setting_mm(p, "machine.bed_size_y", 220), p->scale);

    if (p->have_paths) {
        size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
        ZgLayerStyle style = {.selected = -1, .segment = zg_model_segment(p->model), .first_layer = layer == 0};
        gint64 sel = zg_model_selected(p->model);
        style.fade_others = sel >= 0 && zg_model_isolate(p->model);
        style.focus = zg_model_focus(p->model, &style.focus_first);
        zs_toolpaths tp;
        if (zs_app_toolpaths(core, &tp) == ZS_OK && layer < tp.layer_count) {
            uint32_t first = layer == 0 ? 0 : tp.layer_ends[layer - 1];
            if (sel >= 0 && (uint32_t)sel >= first && (uint32_t)sel < tp.layer_ends[layer]) style.selected = sel - first;
            style.retract = tp.path_retract + first;
            style.retract_count = tp.path_count - first;
            style.more = zg_model_more(p->model, &style.n_more);
            style.first_path = first;
            style.end_path = tp.layer_ends[layer];
        }
        zg_draw_layer(cr, &p->paths, &style);
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

/* The start and the end time of a layer, in seconds from the print start. */
static gboolean layer_times(Preview *p, size_t layer, double *t0, double *t1) {
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(p->model), &tp) != ZS_OK || layer >= tp.layer_count) return FALSE;
    uint32_t last = tp.layer_ends[layer];
    uint32_t prev = layer > 0 ? tp.layer_ends[layer - 1] : 0;
    *t0 = prev > 0 ? tp.path_end_time[prev - 1] : 0;
    *t1 = last > 0 ? tp.path_end_time[last - 1] : *t0;
    return TRUE;
}

/* The scrub bar and its label for time t in a layer. */
static void show_scrub(Preview *p, size_t layer, double t) {
    double t0 = 0, t1 = 0;
    if (!p->scrub || !layer_times(p, layer, &t0, &t1)) return;
    double f = t1 > t0 ? CLAMP((t - t0) / (t1 - t0), 0, 1) : 1;
    p->scrub_quiet = TRUE;
    gtk_range_set_value(GTK_RANGE(p->scrub), f);
    p->scrub_quiet = FALSE;
    double in = CLAMP(t - t0, 0, t1 - t0), len = t1 - t0;
    char *text = g_strdup_printf("Layer %zu · %d:%02d / %d:%02d", layer + 1, (int)in / 60, (int)in % 60, (int)len / 60, (int)len % 60);
    gtk_label_set_text(GTK_LABEL(p->scrub_label), text);
    g_free(text);
}

/* A drag of the scrub bar: the nozzle goes to that time in the top layer
 * (the 3D view), and a replay pauses. */
static void on_scrub(GtkRange *range, gpointer data) {
    Preview *p = data;
    if (p->scrub_quiet) return;
    size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
    double t0, t1;
    if (!layer_times(p, layer, &t0, &t1)) return;
    stop_replay(p);
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
    double f = gtk_range_get_value(range);
    p->time = t0 + f * (t1 - t0);
    /* At the end of the layer: whole layers again, as the layer slider
     * shows them (with its bottom knob). */
    if (f >= 1) {
        zg_view3d_set_layer_range(p->view3d, zg_layer_range_get_lo(ZG_LAYER_RANGE(p->slider)), layer);
    } else {
        zg_view3d_set_time(p->view3d, p->time);
    }
    show_scrub(p, layer, p->time);
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
    show_scrub(p, layer, p->time);
    /* The replay shows all layers up to the nozzle. */
    zg_layer_range_set(ZG_LAYER_RANGE(p->slider), 0, layer);
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


/* ---- the plate bar ---- */

static void fill_plates(Preview *p);

static void on_plate_clicked(GtkButton *b, gpointer data) {
    Preview *p = data;
    zg_model_plate_select(p->model, (size_t)GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-plate")));
}

static void on_plate_add(GtkButton *b, gpointer data) {
    Preview *p = data;
    zg_model_plate_add(p->model);
}

static void fill_plates(Preview *p) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->plates))) gtk_box_remove(GTK_BOX(p->plates), child);
    zs_app *core = zg_model_core(p->model);
    size_t n = zs_app_plate_count(core), active = zs_app_plate_active(core);
    for (size_t i = 0; n > 1 && i < n; i++) {
        char label[16];
        g_snprintf(label, sizeof label, "%zu", i + 1);
        GtkWidget *b = gtk_toggle_button_new_with_label(label);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(b), i == active);
        char *tip = g_strdup_printf("Plate %zu: %zu part%s", i + 1, zs_app_plate_parts(core, i), zs_app_plate_parts(core, i) == 1 ? "" : "s");
        gtk_widget_set_tooltip_text(b, tip);
        g_free(tip);
        g_object_set_data(G_OBJECT(b), "zg-plate", GINT_TO_POINTER((int)i));
        g_signal_connect(b, "clicked", G_CALLBACK(on_plate_clicked), p);
        gtk_box_append(GTK_BOX(p->plates), b);
    }
    GtkWidget *add = gtk_button_new_from_icon_name("list-add-symbolic");
    gtk_widget_set_tooltip_text(add, n > 1 ? "A new plate" : "A new plate: more plates for one print job each (send or export them all from the menu)");
    g_signal_connect(add, "clicked", G_CALLBACK(on_plate_add), p);
    gtk_box_append(GTK_BOX(p->plates), add);
}

static void on_plates_changed(ZgModel *model, gpointer data) {
    fill_plates(data);
}

static void on_isolate(GtkToggleButton *b, gpointer data) {
    Preview *p = data;
    gboolean on = gtk_toggle_button_get_active(b);
    zg_pref_set("isolate", on ? "1" : "0");
    zg_model_set_isolate(p->model, on);
}

static void on_slider(ZgLayerRange *range, gpointer data) {
    Preview *p = data;
    /* A move of the slider stops the replay, and shows whole layers. The
     * 2D view shows the top layer; the 3D view shows lo to hi. */
    stop_replay(p);
    p->time = 0;
    size_t layer = zg_layer_range_get_hi(range);
    load_layer(p, layer);
    zg_view3d_set_layer_range(p->view3d, zg_layer_range_get_lo(range), layer);
    double t0, t1;
    if (layer_times(p, layer, &t0, &t1)) show_scrub(p, layer, t1);
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
    size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
    size_t path = zs_app_pick_layer(core, layer, mx, my);
    /* Shift+click: add the line to the selection, or take it out. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    if (mods & GDK_SHIFT_MASK) {
        if (path != (size_t)-1) zg_model_toggle_more(p->model, (gint64)path);
        return;
    }
    zg_model_select(p->model, path == (size_t)-1 ? -1 : (gint64)path);
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    Preview *p = data;
    /* "Fade others" shows only while a line is selected. */
    gtk_widget_set_visible(p->isolate, path >= 0);
    gtk_widget_queue_draw(p->area);
}

static void on_focus_changed(ZgModel *model, gpointer data) {
    Preview *p = data;
    gtk_widget_queue_draw(p->area);
}

static void preview_free(gpointer data) {
    Preview *p = data;
    /* The 3D view can be gone already (its tick callback with it). */
    if (p->tick && GTK_IS_WIDGET(p->view3d)) gtk_widget_remove_tick_callback(p->view3d, p->tick);
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

/* ---- keyboard navigation ----
 *
 * With a selected line: Left/Right (h/l) select the segment before or after
 * the selected segment in print order, on to the next line at the end of a
 * line (with Shift: the line before or after), and Up/Down (k/j) the
 * nearest line on the layer above or below (a line of the same feature
 * wins a near tie). Escape clears the selection. With no selection:
 * Up/Down (k/j) move the top layer, and with Shift the bottom layer; Page
 * Up/Page Down move 10 layers. toolpath-nav.h finds the next line. */

/* Shows the layer range after a change from the keys. */
static void apply_range(Preview *p) {
    ZgLayerRange *r = ZG_LAYER_RANGE(p->slider);
    stop_replay(p);
    p->time = 0;
    load_layer(p, zg_layer_range_get_hi(r));
    zg_view3d_set_layer_range(p->view3d, zg_layer_range_get_lo(r), zg_layer_range_get_hi(r));
    double t0, t1;
    if (layer_times(p, zg_layer_range_get_hi(r), &t0, &t1)) show_scrub(p, zg_layer_range_get_hi(r), t1);
}

/* The top layer goes to the layer of the selection, so the 2D view shows
 * it and nothing hides it in 3D. */
static void show_layer(Preview *p, size_t layer) {
    ZgLayerRange *r = ZG_LAYER_RANGE(p->slider);
    if (layer == zg_layer_range_get_hi(r)) return;
    zg_layer_range_set(r, MIN(zg_layer_range_get_lo(r), layer), layer);
    apply_range(p);
}



/* "Preview to this layer": the top knob goes to the layer of the selected
 * line, so the part shows as printed up to that line's layer. */
static void cut_to_selection(Preview *p) {
    zs_toolpaths tp;
    gint64 sel = zg_model_selected(p->model);
    if (sel < 0 || zs_app_toolpaths(zg_model_core(p->model), &tp) != ZS_OK || (size_t)sel >= tp.path_count) return;
    show_layer(p, zg_toolpaths_layer_of(&tp, (size_t)sel));
}

/* "Show all layers": the knobs go to the first and the last layer. */
static void show_all_layers(Preview *p) {
    if (p->layer_count == 0) return;
    zg_layer_range_set(ZG_LAYER_RANGE(p->slider), 0, p->layer_count - 1);
    apply_range(p);
}

static void on_cut_to_layer(GSimpleAction *a, GVariant *v, gpointer data) { cut_to_selection(data); }
static void on_all_layers(GSimpleAction *a, GVariant *v, gpointer data) { show_all_layers(data); }

gboolean zg_preview_is_cut(GtkWidget *preview) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    if (!p || p->layer_count == 0) return FALSE;
    ZgLayerRange *r = ZG_LAYER_RANGE(p->slider);
    return zg_layer_range_get_lo(r) > 0 || zg_layer_range_get_hi(r) + 1 < p->layer_count;
}

static gboolean on_preview_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Preview *p = data;
    if (mods & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;
    /* Typing in a text field, and a popup menu (the context menu, the
     * color menu), keep their keys: Esc closes the menu, the arrows move
     * in it. */
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(p->area));
    if (focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    if (zg_view3d_menu_open(p->view3d)) return FALSE;
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(p->model), &tp) != ZS_OK || tp.layer_count == 0) return FALSE;
    gint64 sel = zg_model_selected(p->model);
    int dir = 0;      /* -1 back, +1 forward: along the print */
    int layer_dir = 0; /* -1 down, +1 up */
    int jump = 1;
    switch (key) {
    case GDK_KEY_Left: case GDK_KEY_h: dir = -1; break;
    case GDK_KEY_Right: case GDK_KEY_l: dir = 1; break;
    case GDK_KEY_Up: case GDK_KEY_k: case GDK_KEY_K: layer_dir = 1; break;
    case GDK_KEY_Down: case GDK_KEY_j: case GDK_KEY_J: layer_dir = -1; break;
    case GDK_KEY_Page_Up: layer_dir = 1; jump = 10; break;
    case GDK_KEY_Page_Down: layer_dir = -1; jump = 10; break;
    case GDK_KEY_Menu:
        gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
        zg_view3d_context_menu(p->view3d);
        return TRUE;
    case GDK_KEY_F10:
        if (!(mods & GDK_SHIFT_MASK)) return FALSE;
        gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
        zg_view3d_context_menu(p->view3d);
        return TRUE;
    case GDK_KEY_c: case GDK_KEY_C:
        /* C: preview to the layer of the selected line. Shift+C: all
         * layers again (some keymaps give c with Shift, not C). */
        if (key == GDK_KEY_C || (mods & GDK_SHIFT_MASK)) {
            show_all_layers(p);
            return TRUE;
        }
        if (sel < 0) return FALSE;
        cut_to_selection(p);
        return TRUE;
    case GDK_KEY_Escape:
        if (sel < 0) return FALSE;
        zg_model_select(p->model, -1);
        return TRUE;
    default: return FALSE;
    }
    if (sel >= 0 && (size_t)sel < tp.path_count) {
        if (dir != 0) {
            /* One segment at a time, in print order: on to the next line
             * after the last segment. Shift: a whole line at a time. */
            gint64 path = sel, seg = zg_model_segment(p->model);
            if (!zg_toolpaths_step(&tp, &path, &seg, dir, (mods & GDK_SHIFT_MASK) != 0)) return TRUE;
            zg_model_select_segment(p->model, path, seg);
            show_layer(p, zg_toolpaths_layer_of(&tp, (size_t)path));
            return TRUE;
        }
        /* Up or down: the nearest line, jump layers away (a layer with no
         * lines is passed). */
        long layer = (long)zg_toolpaths_layer_of(&tp, (size_t)sel);
        long target = CLAMP(layer + layer_dir * jump, 0, (long)tp.layer_count - 1);
        while (target != layer) {
            gint64 hit = zg_toolpaths_nearest_on_layer(&tp, (size_t)sel, (size_t)target);
            if (hit >= 0) {
                zg_model_select(p->model, hit);
                show_layer(p, (size_t)target);
                return TRUE;
            }
            target += layer_dir;
            if (target < 0 || target >= (long)tp.layer_count) break;
        }
        return TRUE;
    }
    /* No selection: ← and → move the nozzle through the top layer (2 % of
     * the layer a step), and the other keys move the layers. */
    if (dir != 0 && p->scrub) {
        double f = gtk_range_get_value(GTK_RANGE(p->scrub)) + dir * 0.02;
        gtk_range_set_value(GTK_RANGE(p->scrub), CLAMP(f, 0, 1));
        return TRUE;
    }
    if (layer_dir == 0) return FALSE;
    ZgLayerRange *r = ZG_LAYER_RANGE(p->slider);
    long lo = (long)zg_layer_range_get_lo(r), hi = (long)zg_layer_range_get_hi(r);
    long n = (long)tp.layer_count;
    if (mods & GDK_SHIFT_MASK) {
        lo = CLAMP(lo + layer_dir * jump, 0, n - 1);
        if (hi < lo) hi = lo;
    } else {
        hi = CLAMP(hi + layer_dir * jump, 0, n - 1);
        if (lo > hi) lo = hi;
    }
    zg_layer_range_set(r, (size_t)lo, (size_t)hi);
    apply_range(p);
    return TRUE;
}

/* A press in the preview gives it the keyboard focus, so the keys work
 * after a click on a line. */
static void on_preview_press(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    GtkWidget *box = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    gtk_widget_grab_focus(box);
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

    /* Two knobs: the top layer and the bottom layer that show. */
    p->slider = zg_layer_range_new();
    gtk_widget_set_vexpand(p->slider, TRUE);
    gtk_widget_set_sensitive(p->slider, FALSE);
    g_signal_connect(p->slider, "changed", G_CALLBACK(on_slider), p);

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
    /* With a selected line: fade the other lines, or keep their colors. */
    p->isolate = gtk_toggle_button_new_with_label("Fade others");
    gtk_widget_set_tooltip_text(p->isolate, "Show only the selected line solid, and the other lines as faint ghosts");
    gtk_widget_set_visible(p->isolate, FALSE);
    g_signal_connect(p->isolate, "toggled", G_CALLBACK(on_isolate), p);
    gtk_box_append(GTK_BOX(bar), p->isolate);
    p->plates = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(p->plates, "linked");
    gtk_widget_set_margin_start(p->plates, 6);
    gtk_box_append(GTK_BOX(bar), p->plates);
    gtk_widget_set_halign(bar, GTK_ALIGN_START);
    gtk_widget_set_valign(bar, GTK_ALIGN_START);
    gtk_widget_set_margin_start(bar, 10);
    gtk_widget_set_margin_top(bar, 10);

    /* The layer slider: a thin bar on the right edge, with the layer and
     * the z (or the replay time) above it. */
    p->slider_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    /* The on-screen-display style of the theme: the native look of
     * controls over content (as the controls of a video). */
    gtk_widget_add_css_class(p->slider_box, "osd");
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
    gtk_widget_set_focusable(box, TRUE);
    /* The keys of the preview: before its children (the slider) see them. */
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_preview_key), p);
    gtk_widget_add_controller(box, keys);
    GtkGesture *press = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(press), 0);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(press), GTK_PHASE_CAPTURE);
    g_signal_connect(press, "pressed", G_CALLBACK(on_preview_press), NULL);
    gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(press));
    gtk_overlay_set_child(GTK_OVERLAY(box), stack);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), bar);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), p->slider_box);

    /* The scrub bar: a short bar in the middle of the bottom edge. */
    p->scrub = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001);
    gtk_scale_set_draw_value(GTK_SCALE(p->scrub), FALSE);
    gtk_range_set_value(GTK_RANGE(p->scrub), 1);
    gtk_widget_set_size_request(p->scrub, 300, -1);
    gtk_widget_set_tooltip_text(p->scrub, "Move the nozzle through the top layer: the left end is the start of the layer, the right end the layer done. ← and → with no selected line move it too.");
    g_signal_connect(p->scrub, "value-changed", G_CALLBACK(on_scrub), p);
    p->scrub_label = gtk_label_new("");
    gtk_widget_add_css_class(p->scrub_label, "zg-scrub-label");
    p->scrub_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(p->scrub_box, "osd");
    gtk_widget_add_css_class(p->scrub_box, "zg-scrub");
    gtk_box_append(GTK_BOX(p->scrub_box), p->scrub);
    gtk_box_append(GTK_BOX(p->scrub_box), p->scrub_label);
    gtk_widget_set_halign(p->scrub_box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(p->scrub_box, GTK_ALIGN_END);
    gtk_widget_set_margin_bottom(p->scrub_box, 10);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), p->scrub_box);
    gtk_widget_set_size_request(stack, 200, -1);
    g_object_set_data_full(G_OBJECT(box), "zg-preview", p, preview_free);
    /* For the 3D context menu (a child of the preview). */
    static const GActionEntry actions[] = {
        {.name = "cut-to-layer", .activate = on_cut_to_layer},
        {.name = "all-layers", .activate = on_all_layers},
    };
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), actions, G_N_ELEMENTS(actions), p);
    gtk_widget_insert_action_group(box, "preview", G_ACTION_GROUP(group));
    g_object_unref(group);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), p);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plates_changed), p);
    fill_plates(p);
    g_signal_connect_swapped(model, "segment-changed", G_CALLBACK(gtk_widget_queue_draw), p->area);
    /* The last choice of "Fade others". */
    char *iso = zg_pref_get("isolate", "0");
    if (strcmp(iso, "1") == 0) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(p->isolate), TRUE);
    g_free(iso);
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
    size_t old_layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
    p->layer_count = zs_app_layer_count(core);
    if (p->layer_count == 0) return;

    /* Keep the same layer if it still exists. On the first result, show the
     * top layer. */
    size_t layer = (old_count == 0 || old_layer >= p->layer_count) ? p->layer_count - 1 : old_layer;
    ZgLayerRange *range = ZG_LAYER_RANGE(p->slider);
    size_t lo = old_count == 0 ? 0 : MIN(zg_layer_range_get_lo(range), layer);
    /* For development and screenshots: ZSLICE_LAYERS=lo,hi on the first
     * result. */
    const char *env = old_count == 0 ? g_getenv("ZSLICE_LAYERS") : NULL;
    if (env && strchr(env, ',')) {
        lo = (size_t)atol(env);
        layer = MIN((size_t)atol(strchr(env, ',') + 1), p->layer_count - 1);
    }
    zg_layer_range_set_count(range, p->layer_count);
    zg_layer_range_set(range, lo, layer);
    gtk_widget_set_sensitive(p->slider, p->layer_count > 1);
    if (old_count == 0) p->fitted = FALSE;
    load_layer(p, layer);
    zg_view3d_reload(p->view3d);
    show_legend(p);
    zg_view3d_set_layer_range(p->view3d, zg_layer_range_get_lo(range), layer);
    double t0, t1;
    if (layer_times(p, layer, &t0, &t1)) show_scrub(p, layer, t1);
}

void zg_preview_show_layer(GtkWidget *preview, size_t layer) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    if (!p || layer >= p->layer_count) return;
    show_layer(p, layer);
}
