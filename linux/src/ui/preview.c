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
#include "widgets.h"
#include "float.h"

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
    /* The last press in the preview (the point of a pick, for the line
     * card). */
    double pick_x, pick_y;
    gboolean fitted;
    /* The replay. */
    GtkWidget *stack;
    GtkWidget *slider_box;
    /* The tools (select, move, measure), and the readout of the measure
     * tape. */
    GtkWidget *tools[4]; /* by ZgTool */
    GtkWidget *measure_label;
    /* The gaps view: the toggle, and the number of gaps of the layer. */
    GtkWidget *gaps, *gap_count;
    GtkWidget *check, *check_list; /* the printability check */
    /* The plates: a button for each, and "+". */
    GtkWidget *plates;
    /* The scrub bar: the nozzle through the top layer (0 its start, 1 the
     * layer done), and its time label. */
    GtkWidget *scrub, *scrub_label, *scrub_box;
    /* The box at the bottom of the preview: the scrub bar and the timeline. */
    GtkWidget *bottom;
    gboolean scrub_quiet;
    GtkWidget *colors;
    GtkWidget *legend;
    GtkWidget *play;
    GtkWidget *speed;
    guint tick;
    gint64 last_frame;
    double time;
    /* The move of the nozzle from one segment to the next (h and l): from
     * print time step_from to step_to, in step_dur seconds. */
    guint step_tick;
    gint64 step_t0;
    double step_from, step_to, step_dur, step_now;
    gboolean step_valid;
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

/* The number of gaps of the top layer, next to the toggle. */
static void update_gap_count(Preview *p) {
    if (!p->gap_count) return;
    const zs_gap *gaps = NULL;
    size_t n = 0;
    gboolean on = zg_model_gaps(p->model);
    size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
    if (on && zs_app_state(zg_model_core(p->model)) == ZS_STATE_DONE &&
        zs_app_layer_gaps(zg_model_core(p->model), layer, &gaps, &n, NULL, NULL) == ZS_OK) {
        double area = 0;
        for (size_t i = 0; i < n; i++) area += gaps[i].area;
        char *text = n == 0 ? g_strdup("No gaps") : g_strdup_printf("%zu gap%s · %.2f mm²", n, n == 1 ? "" : "s", area);
        gtk_label_set_text(GTK_LABEL(p->gap_count), text);
        g_free(text);
        gtk_widget_set_visible(p->gap_count, TRUE);
    } else {
        gtk_widget_set_visible(p->gap_count, FALSE);
    }
}

static void on_gaps_toggled(GtkToggleButton *b, gpointer data) {
    Preview *p = data;
    zg_model_set_gaps(p->model, gtk_toggle_button_get_active(b));
}

static void on_gaps_changed(ZgModel *model, gpointer data) {
    Preview *p = data;
    if (p->gaps && gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(p->gaps)) != zg_model_gaps(model))
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(p->gaps), zg_model_gaps(model));
    update_gap_count(p);
    gtk_widget_queue_draw(p->area);
}

/* The gaps of the layer in the 2D view: red cells, the selected gap
 * brighter. */
static void draw_gaps(Preview *p, cairo_t *cr, size_t layer) {
    const zs_gap *gaps = NULL;
    const zs_gap_run *runs = NULL;
    size_t n = 0, nr = 0;
    if (zs_app_layer_gaps(zg_model_core(p->model), layer, &gaps, &n, &runs, &nr) != ZS_OK) return;
    gint64 sel_layer = -1;
    gint64 sel = zg_model_selected_gap(p->model, &sel_layer);
    for (size_t i = 0; i < n; i++) {
        gboolean chosen = sel == (gint64)i && sel_layer == (gint64)layer;
        if (chosen) cairo_set_source_rgba(cr, 1.0, 0.1, 0.1, 1.0);
        else cairo_set_source_rgba(cr, 0.9, 0.1, 0.15, 0.75);
        for (uint32_t k = 0; k < gaps[i].run_len; k++) {
            const zs_gap_run *r = &runs[gaps[i].run_start + k];
            cairo_rectangle(cr, r->x0, r->y - 0.02, r->x1 - r->x0, 0.04);
        }
        cairo_fill(cr);
    }
}

static void show_layer(Preview *p, size_t layer);

/* The printability check (zs_app_checks): a list of the issues of the
 * slice, the worst first. It runs when the list opens, so a slice stays
 * fast. A click on an issue shows its layer. */
/* The path of `layer` with a point nearest to (x, y), or -1. With
 * `feature` >= 0, a path of that feature if the layer has one. */
static gint64 nearest_path(const zs_toolpaths *tp, size_t layer, double x, double y, int feature) {
    if (layer >= tp->layer_count) return -1;
    size_t first = layer == 0 ? 0 : tp->layer_ends[layer - 1], last = tp->layer_ends[layer];
    gboolean has = FALSE;
    if (feature >= 0) for (size_t path = first; path < last; path++) has = has || tp->path_features[path] == feature;
    gint64 best = -1;
    double best_d = G_MAXDOUBLE;
    for (size_t path = first; path < last; path++) {
        if (has && tp->path_features[path] != feature) continue;
        uint32_t a = path == 0 ? 0 : tp->path_ends[path - 1], b = tp->path_ends[path];
        for (uint32_t k = a; k < b; k++) {
            double dx = tp->points[2 * k] - x, dy = tp->points[2 * k + 1] - y;
            double d = dx * dx + dy * dy;
            if (d < best_d) {
                best_d = d;
                best = (gint64)path;
            }
        }
    }
    return best;
}

static void on_check_row(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Preview *p = data;
    const zs_issue *is = g_object_get_data(G_OBJECT(row), "zg-issue");
    if (!is || is->layer >= p->layer_count) return;
    show_layer(p, is->layer);
    /* The line of the issue, or the line of its layer nearest to its
     * place, is selected: the view lights it up, and the side panel says
     * what it is. */
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(p->model), &tp) != ZS_OK) return;
    /* The line of the kind of the issue: a bridge line for a bridge, skin
     * for an overhang. */
    int feature = is->kind == ZS_ISSUE_BRIDGE ? ZS_FEATURE_BRIDGE : is->kind == ZS_ISSUE_OVERHANG ? ZS_FEATURE_SKIN : -1;
    gint64 path = is->path != ZS_NO_PATH ? (gint64)is->path : nearest_path(&tp, is->layer, is->x, is->y, feature);
    if (path >= 0) zg_model_select(p->model, path);
    /* The list closes: the view shows the issue. */
    gtk_menu_button_popdown(GTK_MENU_BUTTON(p->check));
}

static void fill_check(Preview *p) {
    GtkListBox *list = GTK_LIST_BOX(p->check_list);
    gtk_list_box_remove_all(list);
    const zs_issue *issues = NULL;
    size_t n = 0;
    const char *text = NULL;
    zs_app *core = zg_model_core(p->model);
    const char *empty = NULL;
    if (zs_app_state(core) != ZS_STATE_DONE) empty = "Slice the plate first.";
    else if (zs_app_checks(core, &issues, &n, &text) != ZS_OK) empty = "The check failed.";
    else if (n == 0) empty = "No issues found.";
    if (empty) {
        GtkWidget *l = gtk_label_new(empty);
        gtk_widget_add_css_class(l, "dim-label");
        gtk_widget_set_margin_top(l, 12);
        gtk_widget_set_margin_bottom(l, 12);
        gtk_list_box_append(list, l);
        return;
    }
    static const char *icons[] = {"dialog-information-symbolic", "dialog-warning-symbolic", "dialog-error-symbolic"};
    for (size_t i = 0; i < n; i++) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_start(row, 6);
        gtk_widget_set_margin_end(row, 6);
        gtk_widget_set_margin_top(row, 4);
        gtk_widget_set_margin_bottom(row, 4);
        GtkWidget *icon = gtk_image_new_from_icon_name(icons[MIN(issues[i].severity, 2)]);
        gtk_widget_set_valign(icon, GTK_ALIGN_START);
        if (issues[i].severity == 2) gtk_widget_add_css_class(icon, "zg-issue-problem");
        else if (issues[i].severity == 1) gtk_widget_add_css_class(icon, "zg-issue-warning");
        gtk_box_append(GTK_BOX(row), icon);
        char *t = g_strndup(text + issues[i].text_start, issues[i].text_len);
        GtkWidget *l = gtk_label_new(t);
        g_free(t);
        gtk_label_set_wrap(GTK_LABEL(l), TRUE);
        gtk_label_set_xalign(GTK_LABEL(l), 0);
        gtk_label_set_max_width_chars(GTK_LABEL(l), 48);
        gtk_box_append(GTK_BOX(row), l);
        gtk_list_box_append(list, row);
        GtkWidget *r = gtk_widget_get_parent(row);
        /* The issues stay valid until the next slice; the list is filled
         * again each time it opens. */
        g_object_set_data(G_OBJECT(r), "zg-issue", (gpointer)&issues[i]);
    }
}

static void on_check_shown(GtkPopover *pop, gpointer data) {
    Preview *p = data;
    fill_check(p);
    /* For development: ZSLICE_CHECK_PICK=n clicks issue n. */
    const char *pick = g_getenv("ZSLICE_CHECK_PICK");
    GtkListBoxRow *row = pick ? gtk_list_box_get_row_at_index(GTK_LIST_BOX(p->check_list), atoi(pick)) : NULL;
    if (row) {
        on_check_row(GTK_LIST_BOX(p->check_list), row, p);
        gtk_popover_popdown(pop);
    }
}

static void load_layer(Preview *p, size_t layer) {
    free_paths(p);
    update_gap_count(p);
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
        zg_layer_range_set_note(ZG_LAYER_RANGE(p->slider), slowed ? "❄ " : NULL);
    } else {
        gtk_label_set_text(GTK_LABEL(p->label), "");
    }
    gtk_widget_queue_draw(p->area);
}

/* The readout of the measure tape floats on the tape: over the middle of
 * the tape, or next to its first point. With no point, the hint stays
 * under the toolbar. */
static void place_measure(Preview *p) {
    if (!p->measure_label || !gtk_widget_get_visible(p->measure_label)) return;
    const double *m = NULL;
    int n = zg_model_measure(p->model, &m);
    if (n == 0) {
        if (zg_float_get(p->measure_label, NULL, NULL)) zg_float_unplace(p->measure_label);
        return;
    }
    double wx = n == 2 ? (m[0] + m[3]) / 2 : m[0], wy = n == 2 ? (m[1] + m[4]) / 2 : m[1], wz = n == 2 ? (m[2] + m[5]) / 2 : m[2];
    double x, y;
    if (strcmp(gtk_stack_get_visible_child_name(GTK_STACK(p->stack)), "3d") == 0) {
        if (!zg_view3d_pixel_of(p->view3d, wx, wy, wz, &x, &y)) return;
    } else {
        int h = gtk_widget_get_height(p->area);
        x = p->ox + wx * p->scale;
        y = h - (p->oy + wy * p->scale);
    }
    int lw = 0, lh = 0;
    gtk_widget_measure(p->measure_label, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &lw, NULL, NULL);
    gtk_widget_measure(p->measure_label, GTK_ORIENTATION_VERTICAL, lw, NULL, &lh, NULL, NULL);
    double px = n == 2 ? x - lw / 2.0 : x + 14, py = n == 2 ? y - lh - 12 : y - lh / 2.0;
    double ox, oy;
    if (zg_float_get(p->measure_label, &ox, &oy) && fabs(ox - px) < 0.5 && fabs(oy - py) < 0.5) return;
    zg_float_place(p->measure_label, px, py);
}

static void on_view_frame(gpointer data) {
    place_measure(data);
}

/* The measure tape in the 2D view (the 3D view draws it in the core): a
 * gold line between the points, and a ring at each point. */
static void draw_tape(Preview *p, cairo_t *cr, int h) {
    const double *m = NULL;
    int n = zg_model_measure(p->model, &m);
    if (n == 0) return;
    double px[2], py[2];
    for (int i = 0; i < n; i++) {
        px[i] = p->ox + m[3 * i] * p->scale;
        py[i] = h - (p->oy + m[3 * i + 1] * p->scale);
    }
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    if (n == 2) {
        cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.45);
        cairo_set_line_width(cr, 4);
        cairo_move_to(cr, px[0], py[0]);
        cairo_line_to(cr, px[1], py[1]);
        cairo_stroke(cr);
        cairo_set_source_rgb(cr, 0.96, 0.72, 0.10);
        cairo_set_line_width(cr, 2);
        cairo_move_to(cr, px[0], py[0]);
        cairo_line_to(cr, px[1], py[1]);
        cairo_stroke(cr);
    }
    for (int i = 0; i < n; i++) {
        cairo_arc(cr, px[i], py[i], 5, 0, 2 * G_PI);
        cairo_set_source_rgb(cr, 0.96, 0.72, 0.10);
        cairo_fill_preserve(cr);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.6);
        cairo_set_line_width(cr, 1.5);
        cairo_stroke(cr);
    }
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

    gboolean dark = zg_theme_dark(p->area);
    if (dark) cairo_set_source_rgb(cr, 0.114, 0.114, 0.125);
    else cairo_set_source_rgb(cr, 0.965, 0.969, 0.973);
    cairo_paint(cr);

    if (state == ZS_STATE_EMPTY) {
        draw_message(cr, w, h, "Open an STL file, or drop it here");
        return;
    }
    if (!p->fitted) fit(p);

    cairo_save(cr);
    cairo_translate(cr, p->ox, h - p->oy);
    cairo_scale(cr, p->scale, -p->scale);

    zg_draw_bed(cr, setting_mm(p, "machine.bed_size_x", 220), setting_mm(p, "machine.bed_size_y", 220), p->scale, dark);

    if (p->have_paths) {
        size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
        ZgLayerStyle style = {.selected = -1, .segment = zg_model_segment(p->model), .first_layer = layer == 0, .dark = dark};
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
        if (zg_model_gaps(p->model)) draw_gaps(p, cr, layer);
    }
    cairo_restore(cr);
    draw_tape(p, cr, h);
    place_measure(p);

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
    p->step_valid = FALSE; /* h and l go on from the scrub */
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
    /* After a move of the slider: from the start of the top layer that
     * shows. */
    if (p->time <= 0 && zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider)) + 1 < p->layer_count) {
        double t0, t1;
        if (layer_times(p, zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider)), &t0, &t1)) p->time = t0;
    }
    p->step_valid = FALSE; /* h and l go on from the replay */
    p->last_frame = 0;
    p->tick = gtk_widget_add_tick_callback(p->view3d, on_tick, p, NULL);
    gtk_button_set_icon_name(GTK_BUTTON(p->play), "media-playback-pause-symbolic");
}

/* The print time at the end of segment `seg` of path `path`: the time of
 * the path, spread over its segments by length (as the 3D view does). */
static double segment_end_time(const zs_toolpaths *tp, size_t path, gint64 seg) {
    uint32_t start = path == 0 ? 0 : tp->path_ends[path - 1], end = tp->path_ends[path];
    double t0 = tp->path_start_time[path], t1 = tp->path_end_time[path];
    if (end <= start + 1) return t1;
    gboolean closed = tp->path_closed[path] && end - start > 2;
    uint32_t segs = end - start - 1 + (closed ? 1 : 0);
    double len = 0, run = 0;
    for (uint32_t k = 0; k < segs; k++) {
        uint32_t a = start + k, b = a + 1 < end ? a + 1 : start;
        double d = hypot(tp->points[2 * b] - tp->points[2 * a], tp->points[2 * b + 1] - tp->points[2 * a + 1]);
        len += d;
        if ((gint64)k <= seg) run += d;
    }
    return len > 0 ? t0 + (t1 - t0) * run / len : t1;
}

/* The segment that prints at time t: its path and its index in the path.
 * FALSE if there is no path. */
static gboolean segment_at_time(const zs_toolpaths *tp, double t, gint64 *path_out, gint64 *seg_out) {
    if (tp->path_count == 0) return FALSE;
    /* The first path that ends at or after t. */
    size_t lo = 0, hi = tp->path_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (tp->path_end_time[mid] < t) lo = mid + 1;
        else hi = mid;
    }
    size_t path = MIN(lo, tp->path_count - 1);
    uint32_t start = path == 0 ? 0 : tp->path_ends[path - 1], end = tp->path_ends[path];
    gboolean closed = tp->path_closed[path] && end - start > 2;
    gint64 segs = (gint64)(end - start) - 1 + (closed ? 1 : 0);
    gint64 seg = 0;
    while (seg + 1 < segs && segment_end_time(tp, path, seg) < t) seg++;
    *path_out = (gint64)path;
    *seg_out = seg;
    return TRUE;
}

static gboolean on_step_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    Preview *p = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    if (!p->step_t0) p->step_t0 = now;
    double f = p->step_dur > 0 ? CLAMP((now - p->step_t0) / 1e6 / p->step_dur, 0, 1) : 1;
    /* Linear in print time, so a fast travel looks fast and a slow wall
     * slow, as on the printer. */
    p->step_now = p->step_from + (p->step_to - p->step_from) * f;
    zg_view3d_set_time(p->view3d, p->step_now);
    if (f >= 1) {
        p->step_tick = 0;
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

/* Moves the nozzle to the end of the segment that h or l selected: it
 * prints forward, or takes the plastic back in reverse. */
static void animate_step(Preview *p, const zs_toolpaths *tp, gint64 old_path, gint64 old_seg, gint64 path, gint64 seg) {
    double to = segment_end_time(tp, (size_t)path, seg);
    double from = p->step_valid ? p->step_now : segment_end_time(tp, (size_t)old_path, old_seg);
    if (p->step_tick) gtk_widget_remove_tick_callback(p->view3d, p->step_tick);
    p->step_tick = 0;
    stop_replay(p);
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "3d");
    p->step_from = from;
    p->step_to = to;
    p->step_now = from;
    p->step_valid = TRUE;
    /* Half the print time, from 0.12 s to 0.6 s: a key held down gives a
     * quick move. */
    p->step_dur = CLAMP(fabs(to - from) * 0.5, 0.12, 0.6);
    p->step_t0 = 0;
    zg_view3d_set_time(p->view3d, from);
    p->step_tick = gtk_widget_add_tick_callback(p->view3d, on_step_tick, p, NULL);
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


static void on_slider(ZgLayerRange *range, gpointer data) {
    Preview *p = data;
    /* A move of the slider stops the replay, and shows whole layers. The
     * 2D view shows the top layer; the 3D view shows lo to hi. */
    stop_replay(p);
    p->time = 0;
    /* A move of the slider ends a step of the nozzle (h and l). */
    if (p->step_tick) gtk_widget_remove_tick_callback(p->view3d, p->step_tick);
    p->step_tick = 0;
    p->step_valid = FALSE;
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

/* A click of the measure tape in the 2D view: a point on the top layer,
 * or the center of a circle or an arc there. shift: the point itself. */
static void measure_click_2d(Preview *p, double x, double y, gboolean shift) {
    zs_app *core = zg_model_core(p->model);
    int h = gtk_widget_get_height(p->area);
    double mx = (x - p->ox) / p->scale, my = ((h - y) - p->oy) / p->scale;
    size_t layer = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
    zs_toolpaths tp;
    double z = zs_app_toolpaths(core, &tp) == ZS_OK && layer < tp.layer_count ? tp.layer_z[layer] : 0;
    size_t path = zs_app_pick_layer(core, layer, mx, my);
    if (!shift && path != (size_t)-1) {
        /* The segment of the path nearest to the point. */
        uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
        size_t seg = 0;
        double best = G_MAXDOUBLE;
        for (uint32_t k = a; k + 1 < b; k++) {
            double ax = tp.points[2 * k], ay = tp.points[2 * k + 1], bx = tp.points[2 * k + 2], by = tp.points[2 * k + 3];
            double dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
            double t = l2 > 0 ? CLAMP(((mx - ax) * dx + (my - ay) * dy) / l2, 0, 1) : 0;
            double d = hypot(mx - ax - t * dx, my - ay - t * dy);
            if (d < best) {
                best = d;
                seg = k - a;
            }
        }
        zs_measure m;
        if (zs_app_measure(core, path, seg, &m) == ZS_OK && (m.shape == 1 || m.shape == 2)) {
            zg_model_select_segment(p->model, (gint64)path, (gint64)seg);
            zg_model_measure_add_shape(p->model, m.center_x, m.center_y, z, m.radius, m.shape);
            return;
        }
    }
    zg_model_measure_add(p->model, mx, my, z);
}

/* For tests: ZSLICE_MEASURE=x0,y0,x1,y1 measures between two pixels of the
 * view that shows, 1 s after the first slice. */
static void measure_hook(gpointer data) {
    Preview *p = data;
    char **f = g_strsplit(g_getenv("ZSLICE_MEASURE"), ",", 4);
    if (g_strv_length(f) == 4) {
        zg_model_set_tool(p->model, ZG_TOOL_MEASURE);
        gboolean is3d = strcmp(gtk_stack_get_visible_child_name(GTK_STACK(p->stack)), "3d") == 0;
        for (int i = 0; i < 2; i++) {
            double x = g_ascii_strtod(f[2 * i], NULL), y = g_ascii_strtod(f[2 * i + 1], NULL);
            if (is3d) zg_view3d_measure_click(p->view3d, x, y, FALSE);
            else measure_click_2d(p, x, y, FALSE);
        }
    }
    g_strfreev(f);
}

/* A click (a release near the press) picks the path under the pointer. */
static void on_release(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Preview *p = data;
    if (n != 1 || fabs(x - p->press_x) > 4 || fabs(y - p->press_y) > 4) return;
    zs_app *core = zg_model_core(p->model);
    if (zs_app_state(core) != ZS_STATE_DONE) return;
    if (zg_model_tool(p->model) == ZG_TOOL_MEASURE) {
        GdkModifierType m = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        measure_click_2d(p, x, y, (m & GDK_SHIFT_MASK) != 0);
        return;
    }
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

/* "preview.view": the 2D or the 3D view ("2d", "3d"). */
static void on_view_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Preview *p = data;
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), g_variant_get_string(v, NULL));
}

/* "preview.check": the list of the printability check. */
static void on_check_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Preview *p = data;
    gtk_menu_button_popup(GTK_MENU_BUTTON(p->check));
}
static void on_all_layers(GSimpleAction *a, GVariant *v, gpointer data) { show_all_layers(data); }

gboolean zg_preview_is_cut(GtkWidget *preview) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    if (!p || p->layer_count == 0) return FALSE;
    ZgLayerRange *r = ZG_LAYER_RANGE(p->slider);
    return zg_layer_range_get_lo(r) > 0 || zg_layer_range_get_hi(r) + 1 < p->layer_count;
}

/* The keys of a part, as in the web app (app.js, partKey): Tab and
 * Shift+Tab select the next part and the part before; R is the Turn tool.
 * With a selected part: the arrow keys move it 1 mm (Shift: 10 mm), D
 * duplicates it, and Delete removes it. With the Turn tool: Left and
 * Right turn it on the bed (about Z), Up and Down about X, Page Up and
 * Page Down about Y, 15 degrees (Shift: 5). Returns TRUE for a key of a
 * part. */
static gboolean part_key(Preview *p, guint key, GdkModifierType mods) {
    zs_app *core = zg_model_core(p->model);
    size_t n = zs_app_part_count(core);
    gboolean shift = (mods & GDK_SHIFT_MASK) != 0;
    if (key == GDK_KEY_Tab || key == GDK_KEY_ISO_Left_Tab) {
        /* Only from the view itself: in a card, Tab moves the focus. */
        GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(p->area));
        if (n == 0 || (focus && zg_float_in_card(focus))) return FALSE;
        gint64 i = zg_model_selected_part(p->model);
        int dir = key == GDK_KEY_ISO_Left_Tab || shift ? -1 : 1;
        gint64 j = i < 0 ? (dir > 0 ? 0 : (gint64)n - 1) : ((i + dir) % (gint64)n + (gint64)n) % (gint64)n;
        ZgTool t = zg_model_tool(p->model);
        if (t != ZG_TOOL_MOVE && t != ZG_TOOL_TURN) zg_model_set_tool(p->model, ZG_TOOL_MOVE);
        zg_model_select_part(p->model, j);
        return TRUE;
    }
    if ((key == GDK_KEY_r || key == GDK_KEY_R) && !shift) {
        zg_model_set_tool(p->model, ZG_TOOL_TURN);
        return TRUE;
    }
    gint64 i = zg_model_selected_part(p->model);
    zs_part part;
    if (i < 0 || zs_app_part_get(core, (size_t)i, &part) != ZS_OK) return FALSE;
    if (key == GDK_KEY_d || key == GDK_KEY_D) {
        gint64 copy = zg_model_part_duplicate(p->model, (size_t)i);
        if (copy >= 0) zg_model_select_part(p->model, copy);
        return TRUE;
    }
    if (key == GDK_KEY_Delete || key == GDK_KEY_KP_Delete) {
        /* Ctrl+Z brings it back. */
        zg_model_part_remove(p->model, (size_t)i);
        return TRUE;
    }
    int dx = 0, dy = 0;
    switch (key) {
    case GDK_KEY_Left: dx = -1; break;
    case GDK_KEY_Right: dx = 1; break;
    case GDK_KEY_Up: dy = 1; break;
    case GDK_KEY_Down: dy = -1; break;
    case GDK_KEY_Page_Up:
    case GDK_KEY_Page_Down:
        if (zg_model_tool(p->model) != ZG_TOOL_TURN) return FALSE;
        zg_model_part_turn(p->model, (size_t)i, 1, (shift ? 5 : 15) * (key == GDK_KEY_Page_Up ? 1 : -1));
        return TRUE;
    default: return FALSE;
    }
    if (zg_model_tool(p->model) == ZG_TOOL_TURN) {
        double deg = shift ? 5 : 15;
        if (dx != 0) zg_model_part_rotate(p->model, (size_t)i, part.rotation - dx * deg);
        else zg_model_part_turn(p->model, (size_t)i, 0, dy * deg);
        return TRUE;
    }
    double step = shift ? 10 : 1;
    zg_model_part_move(p->model, (size_t)i, part.x + dx * step, part.y + dy * step);
    return TRUE;
}

static gboolean on_preview_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Preview *p = data;
    if (mods & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;
    /* Typing in a text field, and a popup menu (the context menu, the
     * color menu), keep their keys: Esc closes the menu, the arrows move
     * in it. */
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(p->area));
    if (focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    /* A card over the view (the search, a line or a part card) has its
     * own keys. */
    if (focus && zg_float_in_card(focus)) return FALSE;
    if (zg_view3d_menu_open(p->view3d)) return FALSE;
    /* The tools: S select, M move, T measure (a tape). Esc clears a
     * measure. */
    if (part_key(p, key, mods)) return TRUE;
    switch (key) {
    case GDK_KEY_s: case GDK_KEY_S: zg_model_set_tool(p->model, ZG_TOOL_SELECT); return TRUE;
    case GDK_KEY_m: case GDK_KEY_M: zg_model_set_tool(p->model, ZG_TOOL_MOVE); return TRUE;
    case GDK_KEY_t: case GDK_KEY_T: zg_model_set_tool(p->model, ZG_TOOL_MEASURE); return TRUE;
    case GDK_KEY_g: case GDK_KEY_G: zg_model_set_gaps(p->model, !zg_model_gaps(p->model)); return TRUE;
    case GDK_KEY_Escape:
        if (zg_model_selected_part(p->model) >= 0) {
            zg_model_select_part(p->model, -1);
            return TRUE;
        }
        if (zg_model_measure(p->model, NULL) > 0) {
            zg_model_measure_clear(p->model);
            return TRUE;
        }
        break;
    default: break;
    }
    /* A selected part (Ctrl+click): [ and ] turn it 15 degrees (with
     * Shift: 1 degree), and Delete removes it, after a question. */
    gint64 part = zg_model_selected_part(p->model);
    if (part >= 0 && (key == GDK_KEY_bracketleft || key == GDK_KEY_bracketright || key == GDK_KEY_braceleft ||
                      key == GDK_KEY_braceright)) {
        zs_part info;
        if (zs_app_part_get(zg_model_core(p->model), (size_t)part, &info) != ZS_OK) return TRUE;
        double step = (mods & GDK_SHIFT_MASK) ? 1 : 15;
        if (key == GDK_KEY_bracketleft || key == GDK_KEY_braceleft) step = -step;
        zg_model_part_rotate(p->model, (size_t)part, info.rotation + step);
        return TRUE;
    }
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
    /* h and l go on from what the view shows: the segment at the time of
     * a replay or a scrub, or the end of the top layer when the selected
     * line is on another layer. */
    if (dir != 0 && !p->step_valid) {
        gint64 path = -1, seg = -1;
        size_t top = zg_layer_range_get_hi(ZG_LAYER_RANGE(p->slider));
        if (p->time > 0 && segment_at_time(&tp, p->time, &path, &seg)) {
            /* the segment at the time of the replay */
        } else if (sel < 0 || zg_toolpaths_layer_of(&tp, (size_t)sel) > top) {
            if (top < tp.layer_count && tp.layer_ends[top] > 0) {
                path = (gint64)tp.layer_ends[top] - 1;
                segment_at_time(&tp, tp.path_end_time[path], &path, &seg);
            }
        }
        if (path >= 0) {
            zg_model_select_segment(p->model, path, seg);
            sel = path;
            p->step_valid = FALSE;
            p->time = 0;
        }
    }
    if (sel >= 0 && (size_t)sel < tp.path_count) {
        if (dir != 0) {
            /* One segment at a time, in print order: on to the next line
             * after the last segment. Shift: a whole line at a time. */
            gint64 path = sel, seg = zg_model_segment(p->model);
            gint64 old_path = path, old_seg = seg < 0 ? 0 : seg;
            if (!zg_toolpaths_step(&tp, &path, &seg, dir, (mods & GDK_SHIFT_MASK) != 0)) return TRUE;
            zg_model_select_segment(p->model, path, seg);
            show_layer(p, zg_toolpaths_layer_of(&tp, (size_t)path));
            /* The nozzle moves there, with the travels between. */
            animate_step(p, &tp, old_path, old_seg, path, seg < 0 ? 0 : seg);
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
    Preview *p = data;
    GtkWidget *box = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    p->pick_x = x;
    p->pick_y = y;
    /* A card keeps the focus of its own controls. */
    GtkWidget *target = gtk_widget_pick(box, x, y, GTK_PICK_DEFAULT);
    if (target && zg_float_in_card(target)) return;
    gtk_widget_grab_focus(box);
}

static void on_profiles_marks(ZgModel *model, gpointer data);
static void on_mark_activated(ZgLayerRange *range, guint index, gpointer data);

/* ---- the tools: a group of three buttons at the left of the toolbar ---- */

/* The glyph of a tool, in the color of the text: 0 an arrow (select), 1 a
 * cross of arrows (move), 2 a ruler (measure). */
static void draw_tool(GtkDrawingArea *a, cairo_t *cr, int w, int h, gpointer data) {
    int kind = GPOINTER_TO_INT(data);
    GdkRGBA c;
    gtk_widget_get_color(GTK_WIDGET(a), &c);
    gdk_cairo_set_source_rgba(cr, &c);
    double u = MIN(w, h) / 18.0;
    cairo_translate(cr, (w - 18 * u) / 2, (h - 18 * u) / 2);
    cairo_scale(cr, u, u);
    cairo_set_line_width(cr, 1.5);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    if (kind == 0) {
        const double pts[][2] = {{5, 2}, {5, 15}, {8.2, 12}, {10.5, 16.5}, {12.6, 15.5}, {10.3, 11}, {14.5, 11}};
        cairo_move_to(cr, pts[0][0], pts[0][1]);
        for (size_t i = 1; i < G_N_ELEMENTS(pts); i++) cairo_line_to(cr, pts[i][0], pts[i][1]);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (kind == 1) {
        cairo_move_to(cr, 2, 9);
        cairo_line_to(cr, 16, 9);
        cairo_move_to(cr, 9, 2);
        cairo_line_to(cr, 9, 16);
        const double tips[][3] = {{16, 9, 0}, {2, 9, G_PI}, {9, 16, G_PI / 2}, {9, 2, -G_PI / 2}};
        for (int k = 0; k < 4; k++) {
            double x = tips[k][0], y = tips[k][1], ang = tips[k][2];
            cairo_move_to(cr, x + 3 * cos(ang + 2.4), y + 3 * sin(ang + 2.4));
            cairo_line_to(cr, x, y);
            cairo_line_to(cr, x + 3 * cos(ang - 2.4), y + 3 * sin(ang - 2.4));
        }
        cairo_stroke(cr);
    } else if (kind == 3) {
        /* Turn: an arc with an arrow head. */
        cairo_arc(cr, 9, 9, 6, -G_PI * 0.15, G_PI * 1.45);
        cairo_stroke(cr);
        double ex = 9 + 6 * cos(-G_PI * 0.15), ey = 9 + 6 * sin(-G_PI * 0.15);
        cairo_move_to(cr, ex - 3.5, ey - 1.2);
        cairo_line_to(cr, ex, ey);
        cairo_line_to(cr, ex + 0.6, ey - 3.6);
        cairo_stroke(cr);
    } else if (kind == 4) {
        /* Gaps: a square of lines with a hole. */
        for (int k = 0; k < 4; k++) {
            double y = 4 + k * 3.3;
            cairo_move_to(cr, 3, y);
            cairo_line_to(cr, k == 1 || k == 2 ? 7 : 15, y);
            if (k == 1 || k == 2) {
                cairo_move_to(cr, 11, y);
                cairo_line_to(cr, 15, y);
            }
        }
        cairo_stroke(cr);
        cairo_set_source_rgb(cr, 0.9, 0.15, 0.2);
        cairo_rectangle(cr, 7.8, 6.4, 2.4, 5);
        cairo_fill(cr);
    } else if (kind == 5) {
        /* Check: a check mark in a circle. */
        cairo_arc(cr, 9, 9, 7, 0, 2 * G_PI);
        cairo_stroke(cr);
        cairo_move_to(cr, 5.5, 9.2);
        cairo_line_to(cr, 8, 11.8);
        cairo_line_to(cr, 12.8, 6.4);
        cairo_stroke(cr);
    } else {
        /* A ruler at 45 degrees, with ticks. */
        cairo_save(cr);
        cairo_translate(cr, 9, 9);
        cairo_rotate(cr, -G_PI / 4);
        cairo_rectangle(cr, -8, -3, 16, 6);
        for (int k = -5; k <= 5; k += 2) {
            cairo_move_to(cr, k, -3);
            cairo_line_to(cr, k, k % 4 == 1 || k % 4 == -3 ? 0.5 : -0.8);
        }
        cairo_restore(cr);
        cairo_stroke(cr);
    }
}

static void on_tool_toggled(GtkToggleButton *b, gpointer data) {
    Preview *p = data;
    if (!gtk_toggle_button_get_active(b)) return;
    zg_model_set_tool(p->model, (ZgTool)GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-tool")));
}

static void on_tool_changed_preview(ZgModel *model, gpointer data) {
    Preview *p = data;
    ZgTool t = zg_model_tool(model);
    if (!gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(p->tools[t]))) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(p->tools[t]), TRUE);
    /* The part stays selected for the Move and the Turn tool. */
    if (t != ZG_TOOL_MOVE && t != ZG_TOOL_TURN) zg_model_select_part(model, -1);
    /* The measure tape: a hint until the first point. */
    if (t == ZG_TOOL_MEASURE && zg_model_measure(model, NULL) == 0) {
        gtk_label_set_text(GTK_LABEL(p->measure_label), "Click a point of the print, or a circle or an arc for its size and center. Shift: no snap.");
        gtk_widget_set_visible(p->measure_label, TRUE);
    } else if (t != ZG_TOOL_MEASURE) {
        gtk_widget_set_visible(p->measure_label, FALSE);
    }
}

/* The readout of the measure tape: the distance, and its parts along x, y,
 * and z. */
static void on_measure_preview(ZgModel *model, gpointer data) {
    Preview *p = data;
    const double *m = NULL;
    int n = zg_model_measure(model, &m);
    if (zg_model_tool(model) != ZG_TOOL_MEASURE) {
        gtk_widget_set_visible(p->measure_label, FALSE);
        return;
    }
    char *text;
    /* A circle or an arc at a point: its size, and the point is its
     * center. */
    char *shapes[2] = {NULL, NULL};
    for (int i = 0; i < n; i++) {
        int shape = 0;
        double r = zg_model_measure_radius(model, i, &shape);
        if (r > 0) shapes[i] = shape == 1 ? g_strdup_printf("circle ⌀ %.2f mm (radius %.2f)", 2 * r, r)
                                           : g_strdup_printf("arc radius %.2f mm", r);
    }
    if (n == 0) text = g_strdup("Click a point of the print, or a circle or an arc for its size and center. Shift: no snap.");
    else if (n == 1) {
        if (shapes[0]) text = g_strdup_printf("%s, center %.2f, %.2f mm: click a second point to measure from its center.", shapes[0], m[0], m[1]);
        else text = g_strdup_printf("From %.2f, %.2f, %.2f mm: click a second point.", m[0], m[1], m[2]);
    } else {
        double dx = m[3] - m[0], dy = m[4] - m[1], dz = m[5] - m[2];
        char *what = shapes[0] || shapes[1] ? g_strdup_printf("\nFirst: %s   ·   second: %s", shapes[0] ? shapes[0] : "a point",
                                                               shapes[1] ? shapes[1] : "a point")
                                            : g_strdup("");
        text = g_strdup_printf("%.2f mm%s   ·   ΔX %.2f   ΔY %.2f   ΔZ %.2f   ·   on the bed %.2f mm%s",
                               sqrt(dx * dx + dy * dy + dz * dz), shapes[0] || shapes[1] ? " between the centers" : "", fabs(dx), fabs(dy),
                               fabs(dz), sqrt(dx * dx + dy * dy), what);
        g_free(what);
    }
    g_free(shapes[0]);
    g_free(shapes[1]);
    gtk_label_set_text(GTK_LABEL(p->measure_label), text);
    gtk_widget_set_visible(p->measure_label, TRUE);
    g_free(text);
    place_measure(p);
    gtk_widget_queue_draw(p->area);
}

/* A button of the tool strip: the glyph, and its key in the corner. */
static GtkWidget *strip_button(GtkWidget *b, int glyph_kind, const char *key, const char *tip) {
    GtkWidget *glyph = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(glyph), 20);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(glyph), 20);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(glyph), draw_tool, GINT_TO_POINTER(glyph_kind), NULL);
    GtkWidget *over = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(over), glyph);
    if (key) {
        GtkWidget *k = gtk_label_new(key);
        gtk_widget_add_css_class(k, "zg-strip-key");
        gtk_widget_set_halign(k, GTK_ALIGN_END);
        gtk_widget_set_valign(k, GTK_ALIGN_END);
        gtk_widget_set_can_target(k, FALSE);
        gtk_overlay_add_overlay(GTK_OVERLAY(over), k);
    }
    if (GTK_IS_MENU_BUTTON(b)) gtk_menu_button_set_child(GTK_MENU_BUTTON(b), over);
    else gtk_button_set_child(GTK_BUTTON(b), over);
    gtk_widget_set_tooltip_text(b, tip);
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_add_css_class(b, "zg-strip-button");
    return b;
}

/* The tool strip at the left of the view: the tools of the mouse (Select,
 * Move, Turn, Measure), then the line tools (Gaps, Check). Each button
 * shows its key. */
static GtkWidget *tool_strip(Preview *p) {
    static const struct { ZgTool tool; int glyph; const char *key, *tip; } tools[] = {
        {ZG_TOOL_SELECT, 0, "S", "Select (S): click a line to see what it is, its measurements, and the settings that change it."},
        {ZG_TOOL_MOVE, 1, "M", "Move (M): drag a part to move it, and scroll over it to turn it. The same as Ctrl in the other tools. Tab: the next part."},
        {ZG_TOOL_TURN, 3, "R", "Turn (R): click a part, then drag a ring to turn it about X, Y, or Z, in 15° steps (Shift: 5°). Keys: Left and Right (Z), Up and Down (X), Page Up and Page Down (Y)."},
        {ZG_TOOL_MEASURE, 2, "T", "Measure (T): click two points of the print. The ends of the lines snap; Shift turns the snap off. Esc clears."},
    };
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_add_css_class(box, "zg-float");
    gtk_widget_add_css_class(box, "zg-strip");
    GtkWidget *first = NULL;
    for (size_t k = 0; k < G_N_ELEMENTS(tools); k++) {
        GtkWidget *b = strip_button(gtk_toggle_button_new(), tools[k].glyph, tools[k].key, tools[k].tip);
        g_object_set_data(G_OBJECT(b), "zg-tool", GINT_TO_POINTER(tools[k].tool));
        if (first) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(b), GTK_TOGGLE_BUTTON(first));
        else first = b;
        g_signal_connect(b, "toggled", G_CALLBACK(on_tool_toggled), p);
        p->tools[tools[k].tool] = b;
        gtk_box_append(GTK_BOX(box), b);
    }
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(p->tools[zg_model_tool(p->model)]), TRUE);
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    /* The gaps of the top layer: areas that should be solid that no bead
     * covers (see zs_app_layer_gaps). */
    p->gaps = strip_button(gtk_toggle_button_new(), 4, "G",
                           "Gaps (G): show the gaps of the top layer in red: areas that should be solid that no line covers. Click a gap for the settings that can close it.");
    g_signal_connect(p->gaps, "toggled", G_CALLBACK(on_gaps_toggled), p);
    gtk_box_append(GTK_BOX(box), p->gaps);
    /* The printability check: things that can make the print fail. */
    p->check = strip_button(gtk_menu_button_new(), 5, NULL,
                            "Check the print: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little");
    gtk_menu_button_set_direction(GTK_MENU_BUTTON(p->check), GTK_ARROW_RIGHT);
    gtk_box_append(GTK_BOX(box), p->check);
    gtk_widget_set_halign(box, GTK_ALIGN_START);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(box, 10);
    return box;
}

GtkWidget *zg_preview_new(ZgModel *model) {
    Preview *p = g_new0(Preview, 1);
    p->model = g_object_ref(model);
    p->scale = 1;

    p->area = gtk_drawing_area_new();
    /* The 2D view follows the dark mode, as the 3D view. */
    zg_on_theme_changed(p->area, (void (*)(gpointer))gtk_widget_queue_draw, p->area);
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
    gtk_widget_set_tooltip_text(switcher, "2D: one layer. 3D: the layers up to the slider. In 3D: a left drag orbits, a middle or right drag pans (two fingers pressed down on a touchpad), scroll or pinch to zoom, double-click to reset.");

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
    GtkWidget *strip = tool_strip(p);
    p->gap_count = gtk_label_new("");
    gtk_widget_add_css_class(p->gap_count, "dim-label");
    gtk_widget_set_margin_start(p->gap_count, 6);
    gtk_widget_set_margin_end(p->gap_count, 6);
    gtk_widget_set_visible(p->gap_count, FALSE);
    /* The printability check: things that can make the print fail. */
    GtkWidget *pop = gtk_popover_new();
    p->check_list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(p->check_list), GTK_SELECTION_NONE);
    gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(p->check_list), TRUE);
    g_signal_connect(p->check_list, "row-activated", G_CALLBACK(on_check_row), p);
    GtkWidget *check_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(check_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(check_scroll), 460);
    gtk_widget_set_size_request(check_scroll, 440, -1);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(check_scroll), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(check_scroll), p->check_list);
    gtk_popover_set_child(GTK_POPOVER(pop), check_scroll);
    g_signal_connect(pop, "show", G_CALLBACK(on_check_shown), p);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(p->check), pop);
    p->plates = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(p->plates, "linked");
    gtk_widget_set_margin_start(p->plates, 6);
    gtk_box_append(GTK_BOX(bar), p->plates);
    /* The gap count last: it shows and hides, and the buttons before it
     * stay in place. */
    gtk_box_append(GTK_BOX(bar), p->gap_count);
    gtk_widget_set_halign(bar, GTK_ALIGN_START);
    gtk_widget_set_valign(bar, GTK_ALIGN_START);
    gtk_widget_set_margin_start(bar, 10);
    gtk_widget_set_margin_top(bar, 10);

    /* The layer slider: a thin bar on the right edge, with the layer and
     * the z (or the replay time) above it. */
    p->slider_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    /* The on-screen-display style of the theme: the native look of
     * controls over content (as the controls of a video). */
    gtk_widget_add_css_class(p->slider_box, "zg-layers");
    /* The numbers of the layers are beside the knobs (layer-range.c). */
    gtk_box_append(GTK_BOX(p->slider_box), p->slider);
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
    g_signal_connect(press, "pressed", G_CALLBACK(on_preview_press), p);
    gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(press));
    gtk_overlay_set_child(GTK_OVERLAY(box), stack);
    /* The cards over the view (float.h) have places of their own. */
    zg_float_install(box);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), bar);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), strip);
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
    /* The bottom of the preview: the scrub bar, and under it the timeline
     * of the history (zg_preview_set_timeline). */
    p->bottom = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_halign(p->bottom, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(p->bottom, GTK_ALIGN_END);
    gtk_widget_set_margin_bottom(p->bottom, 10);
    gtk_widget_set_margin_start(p->bottom, 10);
    gtk_widget_set_margin_end(p->bottom, 10);
    gtk_box_append(GTK_BOX(p->bottom), p->scrub_box);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), p->bottom);
    /* The readout of the measure tape, under the toolbar. */
    p->measure_label = gtk_label_new("");
    gtk_widget_add_css_class(p->measure_label, "osd");
    gtk_widget_add_css_class(p->measure_label, "zg-measure-readout");
    gtk_widget_add_css_class(p->measure_label, "numeric");
    gtk_widget_set_halign(p->measure_label, GTK_ALIGN_START);
    gtk_widget_set_valign(p->measure_label, GTK_ALIGN_START);
    gtk_widget_set_margin_start(p->measure_label, 64);
    gtk_widget_set_margin_top(p->measure_label, 58);
    gtk_widget_set_can_target(p->measure_label, FALSE);
    gtk_widget_set_visible(p->measure_label, FALSE);
    gtk_overlay_add_overlay(GTK_OVERLAY(box), p->measure_label);
    gtk_widget_set_size_request(stack, 200, -1);
    g_object_set_data_full(G_OBJECT(box), "zg-preview", p, preview_free);
    /* For the 3D context menu (a child of the preview). */
    static const GActionEntry actions[] = {
        {.name = "cut-to-layer", .activate = on_cut_to_layer},
        {.name = "all-layers", .activate = on_all_layers},
        {.name = "view", .activate = on_view_action, .parameter_type = "s"},
        {.name = "check", .activate = on_check_action},
    };
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), actions, G_N_ELEMENTS(actions), p);
    gtk_widget_insert_action_group(box, "preview", G_ACTION_GROUP(group));
    g_object_unref(group);
    g_signal_connect(model, "gaps-changed", G_CALLBACK(on_gaps_changed), p);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), p);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plates_changed), p);
    fill_plates(p);
    g_signal_connect_swapped(model, "segment-changed", G_CALLBACK(gtk_widget_queue_draw), p->area);
    /* The last choice of "Fade others". */
    char *iso = zg_pref_get("isolate", "0");
    zg_model_set_isolate(model, strcmp(iso, "1") == 0);
    g_free(iso);
    g_signal_connect(model, "focus-changed", G_CALLBACK(on_focus_changed), p);
    g_signal_connect(model, "profiles-changed", G_CALLBACK(on_profiles_marks), p);
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed_preview), p);
    g_signal_connect(model, "measure-changed", G_CALLBACK(on_measure_preview), p);
    g_signal_connect(p->slider, "mark-activated", G_CALLBACK(on_mark_activated), p);
    /* The readout of the tape follows the camera. */
    zg_view3d_on_frame(p->view3d, box, on_view_frame, p);
    return box;
}

/* The label of a setting for a mark: "Infill density". */
static char *setting_label(const char *name, size_t len) {
    for (size_t i = 0; i < zs_setting_count(); i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) == ZS_OK && strlen(info.name) == len && strncmp(info.name, name, len) == 0)
            return g_strdup(info.label);
    }
    return g_strndup(name, len);
}

/* The marks of the layer slider: one for each layer range with changes of
 * its own (a layer profile, or changes for some layers). A range of the
 * whole part gets no mark. */
static void update_marks(Preview *p) {
    zs_app *core = zg_model_core(p->model);
    zs_toolpaths tp;
    if (zs_app_toolpaths(core, &tp) != ZS_OK || tp.layer_count == 0) {
        zg_layer_range_set_marks(ZG_LAYER_RANGE(p->slider), NULL, 0);
        return;
    }
    typedef struct { double z_min, z_max; GString *names; char *profile; } Range;
    GArray *ranges = g_array_new(FALSE, TRUE, sizeof(Range));
    size_t no = zs_app_override_count(core), np = zs_app_profile_count(core);
    for (size_t k = 0; k < no + np; k++) {
        double z_min, z_max;
        char *what = NULL, *profile = NULL;
        if (k < no) {
            zs_override o;
            if (zs_app_override_get(core, k, &o) != ZS_OK) continue;
            z_min = o.z_min, z_max = o.z_max;
            what = setting_label(o.name, o.name_len);
        } else {
            zs_layer_profile lp;
            if (zs_app_profile_get(core, k - no, &lp) != ZS_OK) continue;
            z_min = lp.z_min, z_max = lp.z_max;
            profile = g_strndup(lp.name, lp.name_len);
        }
        if (z_min < -1e4 && z_max > 1e4) {
            g_free(what);
            g_free(profile);
            continue;
        }
        Range *r = NULL;
        for (guint i = 0; i < ranges->len; i++) {
            Range *q = &g_array_index(ranges, Range, i);
            if (fabs(q->z_min - z_min) < 1e-6 && fabs(q->z_max - z_max) < 1e-6) r = q;
        }
        if (!r) {
            Range nr = {z_min, z_max, g_string_new(NULL), NULL};
            g_array_append_val(ranges, nr);
            r = &g_array_index(ranges, Range, ranges->len - 1);
        }
        if (what) {
            if (r->names->len) g_string_append(r->names, ", ");
            g_string_append(r->names, what);
            g_free(what);
        }
        if (profile) {
            g_free(r->profile);
            r->profile = profile;
        }
    }
    GArray *marks = g_array_new(FALSE, FALSE, sizeof(ZgLayerMark));
    for (guint i = 0; i < ranges->len; i++) {
        Range *r = &g_array_index(ranges, Range, i);
        /* The layers with a top z in the range. */
        gint64 lo = -1, hi = -1;
        for (size_t j = 0; j < tp.layer_count; j++) {
            double z = tp.layer_z[j];
            if (z >= r->z_min - 1e-4 && z <= r->z_max + 1e-4) {
                if (lo < 0) lo = (gint64)j;
                hi = (gint64)j;
            }
        }
        if (lo >= 0) {
            char *label = g_strdup_printf("%s%s%s", r->profile ? r->profile : "Changes for these layers",
                                          r->names->len ? ": " : "", r->names->str);
            ZgLayerMark m = {(size_t)lo, (size_t)hi, label};
            g_array_append_val(marks, m);
        }
    }
    zg_layer_range_set_marks(ZG_LAYER_RANGE(p->slider), (ZgLayerMark *)marks->data, marks->len);
    for (guint i = 0; i < marks->len; i++) g_free((char *)g_array_index(marks, ZgLayerMark, i).label);
    for (guint i = 0; i < ranges->len; i++) {
        Range *r = &g_array_index(ranges, Range, i);
        g_string_free(r->names, TRUE);
        g_free(r->profile);
    }
    g_array_free(marks, TRUE);
    g_array_free(ranges, TRUE);
}

static void on_profiles_marks(ZgModel *model, gpointer data) {
    update_marks(data);
}

/* A click on a mark: the settings page of its layer range, with its
 * changes. */
static void on_mark_activated(ZgLayerRange *range, guint index, gpointer data) {
    Preview *p = data;
    zs_app *core = zg_model_core(p->model);
    zs_toolpaths tp;
    if (zs_app_toolpaths(core, &tp) != ZS_OK) return;
    size_t layer = zg_layer_range_get_hi(range);
    if (layer >= tp.layer_count) return;
    double z = tp.layer_z[layer];
    /* The range of the mark: the first range that covers its top layer. */
    size_t no = zs_app_override_count(core), np = zs_app_profile_count(core);
    for (size_t k = 0; k < np + no; k++) {
        double z_min, z_max;
        if (k < np) {
            zs_layer_profile lp;
            if (zs_app_profile_get(core, k, &lp) != ZS_OK) continue;
            z_min = lp.z_min, z_max = lp.z_max;
        } else {
            zs_override o;
            if (zs_app_override_get(core, k - np, &o) != ZS_OK) continue;
            z_min = o.z_min, z_max = o.z_max;
        }
        if (z_min < -1e4 && z_max > 1e4) continue;
        if (z >= z_min - 1e-4 && z <= z_max + 1e-4) {
            zg_model_open_profile(p->model, z_min, z_max);
            return;
        }
    }
}

void zg_preview_refresh(GtkWidget *preview) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    zs_app *core = zg_model_core(p->model);
    int state = zs_app_state(core);
    if (state == ZS_STATE_EMPTY) {
        p->fitted = FALSE;
        p->layer_count = 0;
        free_paths(p);
        /* An empty plate: the 3D view and the slider of the plate before
         * go. */
        zg_layer_range_set_count(ZG_LAYER_RANGE(p->slider), 0);
        zg_view3d_reload(p->view3d);
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
    update_marks(p);

    /* Keep the same layer if it still exists. On the first result, show the
     * top layer. */
    /* A slider at the top stays at the top: a new orientation or layer
     * height changes the layer count, and the part must not show cut. */
    gboolean at_top = old_count > 0 && old_layer + 1 >= old_count;
    size_t layer = (old_count == 0 || at_top || old_layer >= p->layer_count) ? p->layer_count - 1 : old_layer;
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
    /* For development: ZSLICE_CHECK=1 opens the check on the first result. */
    if (old_count == 0 && g_getenv("ZSLICE_CHECK")) gtk_menu_button_popup(GTK_MENU_BUTTON(p->check));
    if (old_count == 0 && g_getenv("ZSLICE_MEASURE")) g_timeout_add_once(1000, measure_hook, p);
}

void zg_preview_show_layer(GtkWidget *preview, size_t layer) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    if (!p || layer >= p->layer_count) return;
    show_layer(p, layer);
}

void zg_preview_set_timeline(GtkWidget *preview, GtkWidget *timeline) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    if (!p || !p->bottom) return;
    gtk_widget_set_halign(timeline, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(p->bottom), timeline);
}

GtkWidget *zg_preview_view3d(GtkWidget *preview) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    return p ? p->view3d : NULL;
}

void zg_preview_pick_point(GtkWidget *preview, double *x, double *y) {
    Preview *p = g_object_get_data(G_OBJECT(preview), "zg-preview");
    *x = p ? p->pick_x : 120;
    *y = p ? p->pick_y : 120;
}
