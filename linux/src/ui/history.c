/* history.c: see history.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "history.h"

#include <math.h>
#include <string.h>

static const char *css =
    ".zg-history-step { padding: 8px 10px; }\n"
    ".zg-history-now { background: alpha(@accent_bg_color, 0.18); border-left: 3px solid @accent_bg_color; }\n"
    ".zg-history-later { opacity: 0.55; }\n"
    ".zg-history-badge { font-size: 0.8em; font-weight: bold; padding: 0 6px; border-radius: 8px;"
    " background: @accent_bg_color; color: @accent_fg_color; }\n"
    /* Undo, redo, and the history button: a group of the dock of the
     * preview. */
    ".zg-hist-tools button.zg-tl-tool, .zg-hist-tools menubutton.zg-tl-tool > button {"
    " min-width: 28px; min-height: 28px; padding: 0; border-radius: 14px; }\n"
    ".zg-history-kind { font-size: 0.85em; }\n"
    ".zg-history-foot { padding: 6px 8px; border-top: 1px solid alpha(currentColor, 0.15); }\n"
    /* The list of the changes: a popover over the history button. It is a
     * child of the dock, so it sets its own background. */
    "popover.zg-history-pop > contents { padding: 4px 0; background-color: @theme_bg_color; }\n"
    "popover.zg-history-pop > arrow { background-color: @theme_bg_color; }\n";

static void ensure_css(void) {
    static gboolean done = FALSE;
    if (done) return;
    done = TRUE;
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_string(p, css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
}


/* ---- the badge of a step: a disc in the color of its kind, with a glyph
 * of the kind (zs_history_kind) ---- */

typedef struct {
    const char *kind;
    double r, g, b;
    const char *label;
} KindLook;

static const KindLook looks[] = {
    {"walls", 0.851, 0.282, 0.059, "Walls"},
    {"infill", 0.169, 0.541, 0.243, "Infill"},
    {"surface", 0.110, 0.494, 0.839, "Top and bottom"},
    {"speed", 0.486, 0.227, 0.929, "Speed"},
    {"heat", 0.863, 0.149, 0.149, "Temperature and cooling"},
    {"support", 0.420, 0.447, 0.502, "Support"},
    {"layers", 0.851, 0.565, 0.000, "Layers"},
    {"move", 0.047, 0.580, 0.620, "Move"},
    {"rotate", 0.047, 0.580, 0.620, "Turn"},
    {"scale", 0.047, 0.580, 0.620, "Scale"},
    {"add", 0.047, 0.580, 0.620, "Part added"},
    {"remove", 0.047, 0.580, 0.620, "Part removed"},
    {"quality", 0.859, 0.153, 0.467, "Quality"},
    {"printer", 0.200, 0.255, 0.333, "Printer"},
    {"filament", 0.310, 0.275, 0.898, "Filaments"},
    {"label", 0.635, 0.110, 0.686, "Labels"},
    {"other", 0.500, 0.500, 0.500, "Other"},
    {"start", 0.500, 0.500, 0.500, "Start"},
};

static const KindLook *look_of(const char *kind) {
    for (size_t i = 0; i < G_N_ELEMENTS(looks); i++)
        if (strcmp(looks[i].kind, kind) == 0) return &looks[i];
    return &looks[G_N_ELEMENTS(looks) - 2];
}

/* The kind of step i: "start" for step 0. */
static const char *step_kind(ZgModel *model, guint i) {
    if (i == 0) return "start";
    char *changes = zg_model_history_changes(model, i);
    const char *k = zs_history_kind(changes ? changes : "", changes ? strlen(changes) : 0);
    g_free(changes);
    return k;
}

/* A rectangle with round corners of radius r, in the units of the glyph. */
static void round_rect(cairo_t *cr, double cx, double cy, double u, double x, double y, double w, double h, double r) {
    x = cx + (x - 9) * u, y = cy + (y - 9) * u, w *= u, h *= u, r *= u;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

/* A path of points of the glyph: n pairs of x, y. */
static void poly(cairo_t *cr, double cx, double cy, double u, const double *pts, int n, gboolean close) {
    cairo_move_to(cr, cx + (pts[0] - 9) * u, cy + (pts[1] - 9) * u);
    for (int i = 1; i < n; i++) cairo_line_to(cr, cx + (pts[2 * i] - 9) * u, cy + (pts[2 * i + 1] - 9) * u);
    if (close) cairo_close_path(cr);
}

/* The glyph of a kind, in white, in a box of size u * 20 around (cx, cy).
 * The paths are the SVG glyphs of the web app (GLYPHS in
 * web/app/history.js), in their box of 18 units. */
static void draw_glyph(cairo_t *cr, const char *k, double cx, double cy, double u) {
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_set_line_width(cr, 1.6 * u);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
#define L(...) poly(cr, cx, cy, u, (const double[]){__VA_ARGS__}, sizeof((const double[]){__VA_ARGS__}) / sizeof(double) / 2, FALSE)
#define Z(...) poly(cr, cx, cy, u, (const double[]){__VA_ARGS__}, sizeof((const double[]){__VA_ARGS__}) / sizeof(double) / 2, TRUE)
#define X(v) (cx + ((v) - 9) * u)
#define Y(v) (cy + ((v) - 9) * u)
    if (!strcmp(k, "walls")) {
        round_rect(cr, cx, cy, u, 2.5, 2.5, 13, 13, 3);
        round_rect(cr, cx, cy, u, 6, 6, 6, 6, 1);
    } else if (!strcmp(k, "infill")) {
        round_rect(cr, cx, cy, u, 2.5, 2.5, 13, 13, 1);
        L(2.5, 9, 9, 2.5);
        L(2.5, 15.5, 15.5, 2.5);
        L(9, 15.5, 15.5, 9);
        L(2.5, 9, 9, 15.5);
        L(2.5, 2.5, 15.5, 15.5);
        L(9, 2.5, 15.5, 9);
    } else if (!strcmp(k, "surface")) {
        L(2.5, 3.5, 15.5, 3.5);
        L(2.5, 14.5, 15.5, 14.5);
        cairo_stroke(cr);
        const double dash[] = {1.6 * u, 1.9 * u};
        cairo_set_dash(cr, dash, 2, 0);
        L(2.5, 6, 15.5, 6);
        L(2.5, 12, 15.5, 12);
        cairo_stroke(cr);
        cairo_set_dash(cr, NULL, 0, 0);
        return;
    } else if (!strcmp(k, "speed")) {
        /* A dial: an arc from (3, 13.5) to (15, 13.5), and its needle. */
        cairo_arc(cr, X(9), Y(11), 6.5 * u, 157.38 * G_PI / 180, 382.62 * G_PI / 180);
        L(9, 11, 12.5, 6.5);
        cairo_new_sub_path(cr);
        cairo_arc(cr, X(9), Y(11), 1 * u, 0, 2 * G_PI);
    } else if (!strcmp(k, "heat")) {
        /* A thermometer. */
        cairo_move_to(cr, X(7), Y(10.6));
        cairo_line_to(cr, X(7), Y(4));
        cairo_arc(cr, X(9), Y(4), 2 * u, G_PI, 2 * G_PI);
        cairo_line_to(cr, X(11), Y(10.6));
        cairo_arc(cr, X(9), Y(13.593), 3.6 * u, -56.25 * G_PI / 180, 236.25 * G_PI / 180);
        cairo_close_path(cr);
        L(9, 12.5, 9, 7);
    } else if (!strcmp(k, "label")) {
        Z(2.5, 4.5, 10.5, 4.5, 15.5, 9, 10.5, 13.5, 2.5, 13.5);
        L(5, 9, 9, 9);
    } else if (!strcmp(k, "filament")) {
        round_rect(cr, cx, cy, u, 2.5, 2.5, 2.5, 13, 1);
        round_rect(cr, cx, cy, u, 13, 2.5, 2.5, 13, 1);
        L(5, 6.5, 13, 6.5);
        L(5, 9, 13, 9);
        L(5, 11.5, 13, 11.5);
    } else if (!strcmp(k, "support")) {
        Z(2, 4.5, 16, 4.5, 14, 7.5, 4, 7.5);
        L(5, 7.5, 5, 15.5);
        L(9, 7.5, 9, 15.5);
        L(13, 7.5, 13, 15.5);
        L(3.5, 15.5, 14.5, 15.5);
    } else if (!strcmp(k, "layers")) {
        Z(9, 2.5, 16, 6, 9, 9.5, 2, 6);
        L(2, 9.5, 9, 13, 16, 9.5);
        L(2, 12.5, 9, 16, 16, 12.5);
    } else if (!strcmp(k, "move")) {
        L(2, 9, 16, 9);
        L(9, 2, 9, 16);
        L(13.7, 6.8, 16, 9, 13.7, 11.2);
        L(4.3, 6.8, 2, 9, 4.3, 11.2);
        L(6.8, 4.3, 9, 2, 11.2, 4.3);
        L(6.8, 13.7, 9, 16, 11.2, 13.7);
    } else if (!strcmp(k, "rotate")) {
        cairo_arc(cr, X(9), Y(9), 5.5 * u, 0, G_PI * 1.75);
        L(13.6, 2.2, 13.6, 5.5, 10.3, 5.5);
    } else if (!strcmp(k, "scale")) {
        L(3, 15, 15, 3);
        L(10, 3, 15, 3, 15, 8);
        L(3, 10, 3, 15, 8, 15);
    } else if (!strcmp(k, "add") || !strcmp(k, "remove")) {
        L(3.5, 9, 14.5, 9);
        if (!strcmp(k, "add")) L(9, 3.5, 9, 14.5);
    } else if (!strcmp(k, "quality")) {
        Z(9, 2.2, 11, 6.5, 15.7, 7.1, 12.3, 10.3, 13.2, 14.9, 9, 12.6, 4.8, 14.9, 5.7, 10.3, 2.3, 7.1, 7, 6.5);
    } else if (!strcmp(k, "printer")) {
        L(5, 6.5, 5, 2.5, 13, 2.5, 13, 6.5);
        L(5, 13, 2.5, 13, 2.5, 6.5, 15.5, 6.5, 15.5, 13, 13, 13);
        Z(5, 10.5, 13, 10.5, 13, 15.5, 5, 15.5);
    } else if (!strcmp(k, "start")) {
        /* A ring with a dot in the middle. */
        cairo_arc(cr, X(9), Y(9), 5.5 * u, 0, 2 * G_PI);
        cairo_stroke(cr);
        cairo_arc(cr, X(9), Y(9), 1.5 * u, 0, 2 * G_PI);
        cairo_fill_preserve(cr);
    } else {
        /* Other: three dots. */
        for (int d = 0; d < 3; d++) {
            cairo_new_sub_path(cr);
            cairo_arc(cr, X(4 + 5 * d), Y(9), 0.6 * u, 0, 2 * G_PI);
        }
    }
#undef L
#undef Z
#undef X
#undef Y
    cairo_stroke(cr);
}

static void draw_badge(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    const KindLook *l = data;
    double r = MIN(w, h) / 2.0;
    cairo_arc(cr, w / 2.0, h / 2.0, r - 0.5, 0, 2 * G_PI);
    cairo_set_source_rgb(cr, l->r, l->g, l->b);
    cairo_fill(cr);
    draw_glyph(cr, l->kind, w / 2.0, h / 2.0, (r * 2) / 20.0 * 0.85);
}

static GtkWidget *kind_badge(const char *kind, int size) {
    GtkWidget *a = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(a), size);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(a), size);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(a), draw_badge, (gpointer)look_of(kind), NULL);
    gtk_widget_set_valign(a, GTK_ALIGN_CENTER);
    gtk_widget_set_can_target(a, FALSE);
    return a;
}

/* The time of a step: "14:32" today, else the date too. */
static char *step_time(gint64 t) {
    if (t == 0) return g_strdup("");
    GDateTime *d = g_date_time_new_from_unix_local(t / G_USEC_PER_SEC);
    GDateTime *now = g_date_time_new_now_local();
    gboolean today = g_date_time_get_day_of_year(d) == g_date_time_get_day_of_year(now) &&
                     g_date_time_get_year(d) == g_date_time_get_year(now);
    char *s = g_date_time_format(d, today ? "%H:%M:%S" : "%b %e, %H:%M");
    g_date_time_unref(d);
    g_date_time_unref(now);
    return s;
}

/* A change that cannot be undone alone: the place of a part. */
/* A change that can be undone alone: the rule of the core. */
static gboolean revertible(const char *line) {
    return zs_history_revertible(line, strlen(line)) != 0;
}

/* ---- keys: the arrows go to the step before or after, and Space goes
 * back to the step shown before (to compare two steps) ---- */

/* ---- the right-click menu of a step: go to it, or clear the history
 * after it ---- */

typedef struct {
    ZgModel *model;
    guint step;
    GtkWidget *popover;
} StepMenu;

static void go_step(ZgModel *model, gint64 i);

static void on_menu_go(GtkButton *b, gpointer data) {
    StepMenu *m = data;
    gtk_popover_popdown(GTK_POPOVER(m->popover));
    go_step(m->model, m->step);
}

static void on_menu_clear(GtkButton *b, gpointer data) {
    StepMenu *m = data;
    gtk_popover_popdown(GTK_POPOVER(m->popover));
    zg_model_history_truncate(m->model, m->step);
}

static void step_menu_free(gpointer data) {
    g_free(data);
}

static GtkWidget *menu_button(const char *label, const char *tip, gboolean on, GCallback cb, StepMenu *m) {
    GtkWidget *b = gtk_button_new_with_label(label);
    gtk_widget_add_css_class(b, "flat");
    gtk_label_set_xalign(GTK_LABEL(gtk_button_get_child(GTK_BUTTON(b))), 0);
    if (tip) gtk_widget_set_tooltip_text(b, tip);
    gtk_widget_set_sensitive(b, on);
    g_signal_connect(b, "clicked", cb, m);
    return b;
}

/* Opens the menu of step `step` at (x, y) of `widget`. */
static void step_menu_open(ZgModel *model, GtkWidget *widget, guint step, double x, double y) {
    guint now = zg_model_history_current(model), n = zg_model_history_count(model);
    StepMenu *m = g_new0(StepMenu, 1);
    m->model = model;
    m->step = step;
    GtkWidget *pop = gtk_popover_new();
    m->popover = pop;
    g_object_set_data_full(G_OBJECT(pop), "zg-step-menu", m, step_menu_free);
    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    gtk_widget_add_css_class(pop, "menu");
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    char *name = step == 0 ? g_strdup("the start") : g_strdup_printf("change %u", step);
    char *clear = step < now ? g_strdup_printf("Go to %s and clear the history after it", name)
                             : g_strdup_printf("Clear the history after %s", name);
    gtk_box_append(GTK_BOX(box), menu_button("Go to this change", NULL, step != now, G_CALLBACK(on_menu_go), m));
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(box), menu_button(clear, "The later changes go from the history, and redo cannot bring them back.",
                                             step + 1 < n, G_CALLBACK(on_menu_clear), m));
    g_free(clear);
    g_free(name);
    gtk_popover_set_child(GTK_POPOVER(pop), box);
    gtk_widget_set_parent(pop, widget);
    g_signal_connect(pop, "closed", G_CALLBACK(gtk_widget_unparent), NULL);
    GdkRectangle r = {(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
    gtk_popover_popup(GTK_POPOVER(pop));
}

/* A right click on a widget with "zg-step" data (a mark of the timeline)
 * or on a row of the list under the pointer. */
static void on_step_right_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    ZgModel *model = data;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    GtkWidget *hit = gtk_widget_pick(w, x, y, GTK_PICK_DEFAULT);
    for (GtkWidget *f = hit; f; f = gtk_widget_get_parent(f)) {
        gpointer d = g_object_get_data(G_OBJECT(f), "zg-step");
        if (d || g_object_get_data(G_OBJECT(f), "zg-step-zero")) {
            gtk_gesture_set_state(GTK_GESTURE(g), GTK_EVENT_SEQUENCE_CLAIMED);
            step_menu_open(model, w, GPOINTER_TO_UINT(d), x, y);
            return;
        }
        if (f == w) break;
    }
}

/* Adds the right-click menu of the steps to `w` (the list or the bar). */
static void add_step_menu(GtkWidget *w, ZgModel *model) {
    GtkGesture *g = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(g), GDK_BUTTON_SECONDARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(g), GTK_PHASE_CAPTURE);
    g_signal_connect(g, "pressed", G_CALLBACK(on_step_right_click), model);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(g));
}

static void go_step(ZgModel *model, gint64 i) {
    guint cur = zg_model_history_current(model);
    if (i < 0 || i >= (gint64)zg_model_history_count(model)) return;
    if (zg_model_history_goto(model, (guint)i)) g_object_set_data(G_OBJECT(model), "zg-history-last", GUINT_TO_POINTER(cur + 1));
}

static void flip_step(ZgModel *model) {
    guint last = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(model), "zg-history-last"));
    if (last > 0) go_step(model, (gint64)last - 1);
}

/* ---- the History page ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *list;
    GtkWidget *scroller;
    /* Under the list: clears the steps after the step now. */
    GtkWidget *clear;
} Page;

/* A double click on a change: go to it, and open its setting where it
 * changed (the print, a part, or a layer profile), to edit it. */
typedef struct {
    Page *p;
    guint step;
    char *line;
} EditTarget;

static void edit_target_free(gpointer data) {
    EditTarget *e = data;
    g_free(e->line);
    g_free(e);
}

static void go_step(ZgModel *model, gint64 i);

/* The setting goes to the panel: the popover closes. */
static void close_popover(Page *p) {
    GtkWidget *pop = gtk_widget_get_ancestor(p->list, GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
}

static void edit_change(EditTarget *e) {
    Page *p = e->p;
    ZgModel *model = p->model;
    if (e->step != zg_model_history_current(model)) go_step(model, e->step);
    char **f = g_strsplit(e->line, "\t", 3);
    if (!f[0] || !f[1]) {
        g_strfreev(f);
        return;
    }
    const char *scope = f[0], *key = f[1];
    zs_app *core = zg_model_core(model);
    if (g_str_has_prefix(scope, "part:")) {
        const char *name = scope + strlen("part:");
        gint64 idx = -1;
        for (size_t i = 0; i < zs_app_part_count(core); i++) {
            zs_part part;
            if (zs_app_part_get(core, i, &part) == ZS_OK && part.name && strcmp(part.name, name) == 0) {
                idx = (gint64)i;
                break;
            }
        }
        if (idx < 0) {
            g_strfreev(f);
            return;
        }
        /* The place of the part: the part page. */
        if (key[0] == '(' || !strcmp(key, "position") || !strcmp(key, "rotation") || !strcmp(key, "orientation") || !strcmp(key, "scale")) {
            zg_model_select_part(model, idx);
            gtk_widget_activate_action(p->list, "win.show-page", "s", "selected");
            close_popover(p);
            g_strfreev(f);
            return;
        }
        zg_model_set_part_scope(model, idx);
    } else if (g_str_has_prefix(scope, "layers:")) {
        double lo = 0, hi = 0;
        char **z = g_strsplit(scope + strlen("layers:"), ":", 2);
        if (z[0] && z[1]) {
            lo = g_ascii_strtod(z[0], NULL);
            hi = g_ascii_strtod(z[1], NULL);
            zg_model_open_profile(model, lo, hi);
        }
        g_strfreev(z);
    } else if (zg_model_part_scope(model) >= 0) {
        zg_model_set_part_scope(model, -1);
    }
    if (key[0] != '(' && strcmp(key, "quality") != 0) {
        gtk_widget_activate_action(p->list, "win.show-setting", "s", key);
        close_popover(p);
    }
    g_strfreev(f);
}

static void on_revert(GtkButton *b, gpointer data) {
    Page *p = data;
    const char *line = g_object_get_data(G_OBJECT(b), "zg-change");
    if (line) zg_model_history_revert(p->model, line);
}

static GtkWidget *change_row(Page *p, guint step, const char *scope, const char *words, const char *line, gboolean can_undo) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    if (line && *line) {
        EditTarget *e = g_new0(EditTarget, 1);
        e->p = p;
        e->step = step;
        e->line = g_strdup(line);
        g_object_set_data_full(G_OBJECT(row), "zg-edit", e, edit_target_free);
        gtk_widget_set_tooltip_text(row, "Double-click to edit this setting where it changed.");
    }
    gtk_widget_set_margin_top(row, 4);
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(texts, TRUE);
    GtkWidget *w = gtk_label_new(words);
    gtk_label_set_xalign(GTK_LABEL(w), 0);
    gtk_label_set_wrap(GTK_LABEL(w), TRUE);
    GtkWidget *sc = gtk_label_new(scope);
    gtk_label_set_xalign(GTK_LABEL(sc), 0);
    gtk_widget_add_css_class(sc, "dim-label");
    gtk_widget_add_css_class(sc, "caption");
    gtk_box_append(GTK_BOX(texts), w);
    gtk_box_append(GTK_BOX(texts), sc);
    gtk_box_append(GTK_BOX(row), texts);
    if (can_undo && line) {
        GtkWidget *undo = gtk_button_new_from_icon_name("edit-undo-symbolic");
        gtk_widget_add_css_class(undo, "flat");
        gtk_widget_set_valign(undo, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text(undo, "Undo only this change. The later changes stay.");
        g_object_set_data_full(G_OBJECT(undo), "zg-change", g_strdup(line), g_free);
        g_signal_connect(undo, "clicked", G_CALLBACK(on_revert), p);
        gtk_box_append(GTK_BOX(row), undo);
    }
    return row;
}

static GtkWidget *step_row(Page *p, guint i) {
    guint now = zg_model_history_current(p->model);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(box, "zg-history-step");
    if (i == now) gtk_widget_add_css_class(box, "zg-history-now");
    else if (i > now) gtk_widget_add_css_class(box, "zg-history-later");
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    char *t = step_time(zg_model_history_time(p->model, i));
    char *title = i == 0 ? g_strdup("Start") : g_strdup_printf("Change %u", i);
    GtkWidget *tl = gtk_label_new(title);
    gtk_widget_add_css_class(tl, "heading");
    gtk_label_set_xalign(GTK_LABEL(tl), 0);
    GtkWidget *tt = gtk_label_new(t);
    gtk_widget_add_css_class(tt, "dim-label");
    gtk_widget_add_css_class(tt, "numeric");
    gtk_widget_set_hexpand(tt, TRUE);
    gtk_label_set_xalign(GTK_LABEL(tt), 0);
    const char *kind = step_kind(p->model, i);
    gtk_box_append(GTK_BOX(head), kind_badge(kind, 22));
    gtk_box_append(GTK_BOX(head), tl);
    if (i > 0) {
        GtkWidget *kl = gtk_label_new(look_of(kind)->label);
        gtk_widget_add_css_class(kl, "dim-label");
        gtk_widget_add_css_class(kl, "zg-history-kind");
        gtk_box_append(GTK_BOX(head), kl);
    }
    gtk_box_append(GTK_BOX(head), tt);
    if (i == now) {
        GtkWidget *badge = gtk_label_new("Now");
        gtk_widget_add_css_class(badge, "zg-history-badge");
        gtk_box_append(GTK_BOX(head), badge);
    }
    g_free(t);
    g_free(title);
    gtk_box_append(GTK_BOX(box), head);
    if (i == 0) {
        GtkWidget *l = gtk_label_new("The settings and the plate when the history started.");
        gtk_label_set_xalign(GTK_LABEL(l), 0);
        gtk_label_set_wrap(GTK_LABEL(l), TRUE);
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(box), l);
        return box;
    }
    char *changes = zg_model_history_changes(p->model, i);
    char *words = zg_model_history_describe(p->model, changes);
    char **cl = g_strsplit(changes ? changes : "", "\n", -1);
    char **wl = g_strsplit(words, "\n", -1);
    int n = 0;
    for (int k = 0; wl[k] && cl[k]; k++) {
        if (!*wl[k]) continue;
        char *tab = strchr(wl[k], '\t');
        if (!tab) continue;
        *tab = 0;
        /* Only the changes of the step now and before can be undone alone:
         * a later step is not in the settings now. */
        gboolean can = i <= now && revertible(cl[k]);
        gtk_box_append(GTK_BOX(box), change_row(p, i, wl[k], tab + 1, cl[k], can));
        n++;
    }
    if (n == 0) {
        GtkWidget *l = gtk_label_new("Other changes (formulas, global settings, or the plate).");
        gtk_label_set_xalign(GTK_LABEL(l), 0);
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(box), l);
    }
    g_strfreev(cl);
    g_strfreev(wl);
    g_free(words);
    g_free(changes);
    return box;
}

static void page_fill_focus(Page *p, gboolean take_focus) {
    GtkRoot *root = gtk_widget_get_root(p->list);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    gboolean had_focus = take_focus || (focus && gtk_widget_is_ancestor(focus, p->list));
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->list))) gtk_list_box_remove(GTK_LIST_BOX(p->list), child);
    guint n = zg_model_history_count(p->model);
    guint later = n > 0 ? n - 1 - zg_model_history_current(p->model) : 0;
    gtk_widget_set_visible(p->clear, later > 0);
    char *clear = later == 1 ? g_strdup("Clear the later change") : g_strdup_printf("Clear the %u later changes", later);
    gtk_button_set_label(GTK_BUTTON(p->clear), clear);
    g_free(clear);
    if (n == 0) return;
    /* The newest first. */
    for (guint k = n; k-- > 0;) {
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), step_row(p, k));
        g_object_set_data(G_OBJECT(row), "zg-step", GUINT_TO_POINTER(k));
        if (k == 0) g_object_set_data(G_OBJECT(row), "zg-step-zero", GINT_TO_POINTER(1));
        gtk_list_box_append(GTK_LIST_BOX(p->list), row);
        if (k == zg_model_history_current(p->model) && had_focus) gtk_widget_grab_focus(row);
    }
}

static void page_fill(Page *p) {
    page_fill_focus(p, FALSE);
}

/* The page shows: the step now has the focus, so the arrow keys move
 * through the steps at once. */
static gboolean focus_now_row(gpointer data) {
    Page *p = data;
    if (!gtk_widget_get_mapped(p->list)) return G_SOURCE_REMOVE;
    for (GtkWidget *row = gtk_widget_get_first_child(p->list); row; row = gtk_widget_get_next_sibling(row)) {
        if (GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(row), "zg-step")) == zg_model_history_current(p->model)) {
            gtk_widget_grab_focus(row);
            break;
        }
    }
    return G_SOURCE_REMOVE;
}

static void on_page_map(GtkWidget *w, gpointer data) {
    page_fill(data);
    /* After the click on "History": its button takes the focus on the
     * release. */
    g_timeout_add(150, focus_now_row, data);
}

/* Up: the newer step (above), Down: the older step, Space: the step shown
 * before. */
static gboolean on_page_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Page *p = data;
    gint64 cur = zg_model_history_current(p->model);
    switch (key) {
    case GDK_KEY_Up: case GDK_KEY_KP_Up: go_step(p->model, cur + 1); return TRUE;
    case GDK_KEY_Down: case GDK_KEY_KP_Down: go_step(p->model, cur - 1); return TRUE;
    case GDK_KEY_space: flip_step(p->model); return TRUE;
    default: return FALSE;
    }
}

/* A double click in the list: the change under the pointer. The list takes
 * the clicks of its rows, so the gesture is on the list. */
static void on_list_pressed(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Page *p = data;
    if (n != 2) return;
    GtkWidget *w = gtk_widget_pick(p->list, x, y, GTK_PICK_DEFAULT);
    for (; w && w != p->list; w = gtk_widget_get_parent(w)) {
        EditTarget *e = g_object_get_data(G_OBJECT(w), "zg-edit");
        if (e) {
            edit_change(e);
            return;
        }
    }
}

static void on_row(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    Page *p = data;
    guint i = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(row), "zg-step"));
    go_step(p->model, i);
}

static void on_history(ZgModel *model, gpointer data) {
    page_fill(data);
}

static void on_clear_later(GtkButton *b, gpointer data) {
    Page *p = data;
    zg_model_history_truncate(p->model, zg_model_history_current(p->model));
}

/* After a slice: the changes of some layers get their layer numbers. Only
 * while the page shows. */
static void on_page_core(ZgModel *model, int event, double progress, int status, gpointer data) {
    Page *p = data;
    if (event == ZS_EVENT_SLICED && gtk_widget_get_mapped(p->list)) page_fill(p);
}

static void page_free(gpointer data) {
    Page *p = data;
    g_signal_handlers_disconnect_by_data(p->model, p);
    g_object_unref(p->model);
    g_free(p);
}

GtkWidget *zg_history_page_new(ZgModel *model) {
    ensure_css();
    Page *p = g_new0(Page, 1);
    p->model = g_object_ref(model);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    /* One line; the rest is in its tooltip. */
    GtkWidget *help = gtk_label_new("Click a change to see the print as it was then.");
    gtk_widget_set_tooltip_text(help, "The changes of the settings and of the plate, the newest first. "
                                      "↑ and ↓ go to the next change, and Space goes back to the one shown before, "
                                      "to compare two. A new edit there drops the later changes. "
                                      "↶ undoes only one setting and keeps the later changes. "
                                      "Double-click a setting to edit it.");
    gtk_label_set_wrap(GTK_LABEL(help), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(help), 50);
    gtk_label_set_xalign(GTK_LABEL(help), 0);
    gtk_widget_add_css_class(help, "dim-label");
    gtk_widget_set_margin_start(help, 10);
    gtk_widget_set_margin_end(help, 10);
    p->list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(p->list), GTK_SELECTION_NONE);
    gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(p->list), TRUE);
    gtk_widget_add_css_class(p->list, "navigation-sidebar");
    g_signal_connect(p->list, "row-activated", G_CALLBACK(on_row), p);
    add_step_menu(p->list, p->model);
    GtkGesture *dbl = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(dbl), GTK_PHASE_CAPTURE);
    g_signal_connect(dbl, "pressed", G_CALLBACK(on_list_pressed), p);
    gtk_widget_add_controller(p->list, GTK_EVENT_CONTROLLER(dbl));
    GtkEventController *pk = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(pk, GTK_PHASE_CAPTURE);
    g_signal_connect(pk, "key-pressed", G_CALLBACK(on_page_key), p);
    gtk_widget_add_controller(p->list, pk);
    p->scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(p->scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(p->scroller), p->list);
    /* The size of a popover: at most 460 points wide and 480 high. */
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(p->scroller), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(p->scroller), 480);
    gtk_scrolled_window_set_propagate_natural_width(GTK_SCROLLED_WINDOW(p->scroller), TRUE);
    gtk_scrolled_window_set_max_content_width(GTK_SCROLLED_WINDOW(p->scroller), 460);
    gtk_widget_set_vexpand(p->scroller, TRUE);
    p->clear = gtk_button_new_with_label("");
    gtk_widget_add_css_class(p->clear, "flat");
    gtk_widget_set_halign(p->clear, GTK_ALIGN_END);
    gtk_widget_set_tooltip_text(p->clear, "The changes after the step now go from the history. Redo cannot bring them back.");
    g_signal_connect(p->clear, "clicked", G_CALLBACK(on_clear_later), p);
    GtkWidget *foot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(foot, "zg-history-foot");
    gtk_widget_set_hexpand(p->clear, TRUE);
    gtk_box_append(GTK_BOX(foot), p->clear);
    gtk_box_append(GTK_BOX(box), help);
    gtk_box_append(GTK_BOX(box), p->scroller);
    gtk_box_append(GTK_BOX(box), foot);
    g_object_bind_property(p->clear, "visible", foot, "visible", G_BINDING_SYNC_CREATE);
    g_object_set_data_full(G_OBJECT(box), "zg-history", p, page_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_history), p);
    g_signal_connect(model, "core-event", G_CALLBACK(on_page_core), p);
    g_signal_connect(p->list, "map", G_CALLBACK(on_page_map), p);
    page_fill(p);
    return box;
}

/* ---- undo, redo, and the history button ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *undo, *redo, *button, *glyph, *popover, *sum;
    /* The changes since the last open or save, on the button. */
    guint unsaved;
    /* The time of the last open or save (µs, as the steps), or 0. */
    gint64 saved_at;
} Tools;

/* The glyphs of the buttons on the 18 x 18 grid of the tool glyphs
 * (preview.c, draw_tool), as on the web (index.html): 0 undo, 1 redo,
 * 2 the history (a clock with a counter arrow). */
static void draw_tools_glyph(GtkDrawingArea *a, cairo_t *cr, int w, int h, gpointer data) {
    int kind = GPOINTER_TO_INT(data);
    GdkRGBA c;
    gtk_widget_get_color(GTK_WIDGET(a), &c);
    gdk_cairo_set_source_rgba(cr, &c);
    double u = MIN(MIN(w, h), 18) / 18.0;
    cairo_save(cr);
    cairo_translate(cr, (w - 18 * u) / 2, (h - 18 * u) / 2);
    cairo_scale(cr, u, u);
    cairo_set_line_width(cr, 1.5);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    if (kind == 2) {
        cairo_new_sub_path(cr);
        cairo_arc_negative(cr, 9, 9, 5.8, G_PI, -0.75 * G_PI);
        cairo_move_to(cr, 4.9, 1.9);
        cairo_line_to(cr, 4.9, 4.9);
        cairo_line_to(cr, 7.9, 4.9);
        cairo_move_to(cr, 9, 5.8);
        cairo_line_to(cr, 9, 9);
        cairo_line_to(cr, 11.3, 10.5);
    } else {
        /* Undo; redo is undo in a mirror. */
        if (kind == 1) {
            cairo_translate(cr, 18, 0);
            cairo_scale(cr, -1, 1);
        }
        cairo_move_to(cr, 6.5, 3.5);
        cairo_line_to(cr, 3, 7);
        cairo_line_to(cr, 6.5, 10.5);
        cairo_move_to(cr, 3, 7);
        cairo_line_to(cr, 10.5, 7);
        cairo_arc(cr, 10.5, 11.5, 4.5, -G_PI / 2, G_PI / 2);
        cairo_line_to(cr, 8, 16);
    }
    cairo_stroke(cr);
    cairo_restore(cr);
    /* The count of the history button: a disc in the accent color of
     * Adwaita at the top right, with the number. */
    Tools *t = g_object_get_data(G_OBJECT(a), "zg-tools");
    if (!t || t->unsaved == 0) return;
    char text[8];
    g_snprintf(text, sizeof text, t->unsaved > 9 ? "9+" : "%u", t->unsaved);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 8.5);
    cairo_text_extents_t ext;
    cairo_text_extents(cr, text, &ext);
    double r = 6, bw = MAX(2 * r, ext.x_advance + 6), bx = w - bw, by = 0;
    cairo_new_path(cr);
    cairo_arc(cr, bx + r, by + r, r, G_PI / 2, 3 * G_PI / 2);
    cairo_arc(cr, bx + bw - r, by + r, r, -G_PI / 2, G_PI / 2);
    cairo_close_path(cr);
    cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
    cairo_fill(cr);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_move_to(cr, bx + (bw - ext.x_advance) / 2, by + r + ext.height / 2);
    cairo_show_text(cr, text);
}

static GtkWidget *tools_glyph(int kind) {
    GtkWidget *g = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(g), 20);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(g), 20);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(g), draw_tools_glyph, GINT_TO_POINTER(kind), NULL);
    gtk_widget_set_can_target(g, FALSE);
    return g;
}

/* The changes since the last open or save: the steps after the save,
 * and the steps of the save that an undo took back. The times of the
 * steps give them, so the history needs no mark. */
static guint tools_unsaved(Tools *t) {
    guint n = zg_model_history_count(t->model), now = zg_model_history_current(t->model), k = 0;
    for (guint i = 1; i < n; i++) {
        gboolean after = zg_model_history_time(t->model, i) > t->saved_at;
        if (i <= now ? after : !after) k++;
    }
    return k;
}

static void tools_fill(Tools *t) {
    guint n = zg_model_history_count(t->model), now = zg_model_history_current(t->model);
    guint changes = n > 0 ? n - 1 : 0, unsaved = tools_unsaved(t);
    const char *s = changes == 1 ? "" : "s";
    gtk_widget_set_sensitive(t->undo, now > 0);
    gtk_widget_set_sensitive(t->redo, now + 1 < n);
    if (t->unsaved != unsaved) {
        t->unsaved = unsaved;
        gtk_widget_queue_draw(t->glyph);
    }
    char *tip = unsaved > 0 ? g_strdup_printf("History (%u change%s). %u since you opened or saved. Ctrl+H", changes, s, unsaved)
                            : g_strdup_printf("History (%u change%s). Ctrl+H", changes, s);
    gtk_widget_set_tooltip_text(t->button, tip);
    g_free(tip);
    char *sum = changes == 0 ? g_strdup("")
                : now + 1 < n ? g_strdup_printf("%u change%s, at change %u", changes, s, now)
                              : g_strdup_printf("%u change%s", changes, s);
    gtk_label_set_text(GTK_LABEL(t->sum), sum);
    g_free(sum);
}

static void on_tools_history(ZgModel *model, gpointer data) {
    tools_fill(data);
}

static void on_undo(GtkButton *b, gpointer data) {
    zg_model_undo(((Tools *)data)->model);
}

static void on_redo(GtkButton *b, gpointer data) {
    zg_model_redo(((Tools *)data)->model);
}

static void on_pop_close(GtkButton *b, gpointer data) {
    gtk_popover_popdown(GTK_POPOVER(((Tools *)data)->popover));
}

static void tools_free(gpointer data) {
    Tools *t = data;
    g_signal_handlers_disconnect_by_data(t->model, t);
    g_object_unref(t->model);
    g_free(t);
}

/* A round flat button of the group, with glyph `glyph` (a plain button)
 * or with no child yet (a menu button). */
static GtkWidget *tool_button(GtkWidget *b, int glyph, const char *tip) {
    if (GTK_IS_MENU_BUTTON(b)) {
        gtk_menu_button_set_has_frame(GTK_MENU_BUTTON(b), FALSE);
    } else {
        gtk_button_set_child(GTK_BUTTON(b), tools_glyph(glyph));
        gtk_widget_add_css_class(b, "flat");
    }
    gtk_widget_add_css_class(b, "zg-tl-tool");
    gtk_widget_set_valign(b, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(b, tip);
    return b;
}

GtkWidget *zg_history_tools_new(ZgModel *model) {
    ensure_css();
    Tools *t = g_new0(Tools, 1);
    t->model = g_object_ref(model);
    /* A group of the dock: undo, redo, and the history button. The dock
     * paints its background. */
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_widget_add_css_class(bar, "zg-hist-tools");
    t->undo = tool_button(gtk_button_new(), 0, "Undo (Ctrl+Z)");
    t->redo = tool_button(gtk_button_new(), 1, "Redo (Ctrl+Shift+Z)");
    g_signal_connect(t->undo, "clicked", G_CALLBACK(on_undo), t);
    g_signal_connect(t->redo, "clicked", G_CALLBACK(on_redo), t);
    /* The history button: the glyph, and the count at its top right. */
    t->button = tool_button(gtk_menu_button_new(), 2, "History");
    t->glyph = tools_glyph(2);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(t->glyph), 24);
    g_object_set_data(G_OBJECT(t->glyph), "zg-tools", t);
    gtk_menu_button_set_child(GTK_MENU_BUTTON(t->button), t->glyph);
    /* The list of the changes: a popover over the button, with a head. */
    t->popover = gtk_popover_new();
    gtk_widget_add_css_class(t->popover, "zg-history-pop");
    gtk_popover_set_position(GTK_POPOVER(t->popover), GTK_POS_TOP);
    GtkWidget *pop_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(head, 10);
    gtk_widget_set_margin_end(head, 4);
    gtk_widget_set_margin_bottom(head, 4);
    GtkWidget *title = gtk_label_new("History");
    gtk_widget_add_css_class(title, "heading");
    t->sum = gtk_label_new("");
    gtk_widget_add_css_class(t->sum, "dim-label");
    gtk_widget_add_css_class(t->sum, "numeric");
    gtk_widget_set_hexpand(t->sum, TRUE);
    gtk_label_set_xalign(GTK_LABEL(t->sum), 0);
    GtkWidget *close = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_add_css_class(close, "flat");
    gtk_widget_add_css_class(close, "circular");
    gtk_widget_set_tooltip_text(close, "Close (Esc)");
    g_signal_connect(close, "clicked", G_CALLBACK(on_pop_close), t);
    gtk_box_append(GTK_BOX(head), title);
    gtk_box_append(GTK_BOX(head), t->sum);
    gtk_box_append(GTK_BOX(head), close);
    gtk_box_append(GTK_BOX(pop_box), head);
    gtk_box_append(GTK_BOX(pop_box), zg_history_page_new(model));
    gtk_popover_set_child(GTK_POPOVER(t->popover), pop_box);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(t->button), t->popover);
    gtk_box_append(GTK_BOX(bar), t->undo);
    gtk_box_append(GTK_BOX(bar), t->redo);
    gtk_box_append(GTK_BOX(bar), t->button);
    g_object_set_data_full(G_OBJECT(bar), "zg-history-tools", t, tools_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_tools_history), t);
    tools_fill(t);
    return bar;
}

void zg_history_tools_toggle(GtkWidget *tools, gboolean open) {
    Tools *t = g_object_get_data(G_OBJECT(tools), "zg-history-tools");
    if (!t) return;
    if (open || !gtk_widget_get_visible(t->popover)) gtk_popover_popup(GTK_POPOVER(t->popover));
    else gtk_popover_popdown(GTK_POPOVER(t->popover));
}

static gboolean mark_again(gpointer data) {
    Tools *t = g_object_get_data(G_OBJECT(data), "zg-history-tools");
    if (t) {
        t->saved_at = g_get_real_time();
        tools_fill(t);
    }
    return G_SOURCE_REMOVE;
}

void zg_history_tools_mark_saved(GtkWidget *tools) {
    Tools *t = g_object_get_data(G_OBJECT(tools), "zg-history-tools");
    if (!t) return;
    t->saved_at = g_get_real_time();
    tools_fill(t);
    /* The step of an open is in the history 400 ms later (the commit of
     * the model): the mark moves past it. */
    g_timeout_add_full(G_PRIORITY_DEFAULT, 600, mark_again, g_object_ref(tools), g_object_unref);
}
