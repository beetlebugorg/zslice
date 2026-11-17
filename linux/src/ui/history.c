/* history.c: see history.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "history.h"

#include "settings-browser.h"

#include <math.h>
#include <string.h>

static const char *css =
    ".zg-history-step { padding: 8px 10px; }\n"
    ".zg-history-now { background: alpha(@accent_bg_color, 0.18); border-left: 3px solid @accent_bg_color; }\n"
    ".zg-history-later { opacity: 0.55; }\n"
    ".zg-history-badge { font-size: 0.8em; font-weight: bold; padding: 0 6px; border-radius: 8px;"
    " background: @accent_bg_color; color: @accent_fg_color; }\n"
    ".zg-timeline { padding: 3px 8px; border-top: 1px solid alpha(currentColor, 0.15); }\n"
    ".zg-tl-step { min-width: 0; min-height: 0; padding: 2px; margin: 0 1px; border-radius: 99px;"
    " background: none; box-shadow: none; }\n"
    ".zg-tl-step:hover { background: alpha(currentColor, 0.15); }\n"
    ".zg-tl-step.zg-tl-now { box-shadow: 0 0 0 2px @accent_bg_color; }\n"
    ".zg-tl-step.zg-tl-later { opacity: 0.35; }\n"
    ".zg-tl-line { min-width: 10px; min-height: 2px; background: alpha(currentColor, 0.25); }\n";

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

static void arrow_head(cairo_t *cr, double x, double y, double ang, double s) {
    cairo_move_to(cr, x + s * cos(ang + 2.5), y + s * sin(ang + 2.5));
    cairo_line_to(cr, x, y);
    cairo_line_to(cr, x + s * cos(ang - 2.5), y + s * sin(ang - 2.5));
}

/* The glyph of a kind, in white, in a box of size u * 20 around (cx, cy). */
static void draw_glyph(cairo_t *cr, const char *k, double cx, double cy, double u) {
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_set_line_width(cr, 1.6 * u);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
#define P(x, y) (cx + (x) * u), (cy + (y) * u)
    if (!strcmp(k, "walls")) {
        cairo_rectangle(cr, P(-5.5, -5.5), 11 * u, 11 * u);
        cairo_rectangle(cr, P(-2.5, -2.5), 5 * u, 5 * u);
    } else if (!strcmp(k, "infill")) {
        /* Crossed lines in a disc, as a grid infill. */
        cairo_save(cr);
        cairo_arc(cr, cx, cy, 5.8 * u, 0, 2 * G_PI);
        cairo_clip(cr);
        cairo_set_line_width(cr, 1.3 * u);
        for (int d = -1; d <= 1; d++) {
            cairo_move_to(cr, P(-6 + d * 4.5, -6));
            cairo_line_to(cr, P(6 + d * 4.5, 6));
            cairo_move_to(cr, P(6 + d * 4.5, -6));
            cairo_line_to(cr, P(-6 + d * 4.5, 6));
        }
        cairo_stroke(cr);
        cairo_restore(cr);
        return;
    } else if (!strcmp(k, "surface")) {
        for (int d = -1; d <= 1; d++) {
            cairo_move_to(cr, P(-5 + d * 4 - 1, 4));
            cairo_line_to(cr, P(1 + d * 4, -4));
        }
    } else if (!strcmp(k, "speed")) {
        for (int d = 0; d < 2; d++) {
            cairo_move_to(cr, P(-5 + d * 5, -4.5));
            cairo_line_to(cr, P(-0.5 + d * 5, 0));
            cairo_line_to(cr, P(-5 + d * 5, 4.5));
        }
    } else if (!strcmp(k, "heat")) {
        /* A thermometer. */
        cairo_move_to(cr, P(0, -6));
        cairo_line_to(cr, P(0, 2));
        cairo_stroke(cr);
        cairo_arc(cr, P(0, 3.5), 2.6 * u, 0, 2 * G_PI);
        cairo_fill(cr);
        cairo_move_to(cr, P(2.5, -4));
        cairo_line_to(cr, P(4, -4));
        cairo_move_to(cr, P(2.5, -1));
        cairo_line_to(cr, P(4, -1));
    } else if (!strcmp(k, "support")) {
        cairo_move_to(cr, P(-6, -4.5));
        cairo_line_to(cr, P(6, -4.5));
        for (int d = -1; d <= 1; d++) {
            cairo_move_to(cr, P(d * 4, -4.5));
            cairo_line_to(cr, P(d * 4, 5.5));
        }
    } else if (!strcmp(k, "layers")) {
        for (int d = -1; d <= 1; d++) {
            cairo_move_to(cr, P(-5.5, d * 3.8));
            cairo_line_to(cr, P(5.5, d * 3.8));
        }
    } else if (!strcmp(k, "move")) {
        cairo_move_to(cr, P(-6, 0));
        cairo_line_to(cr, P(6, 0));
        cairo_move_to(cr, P(0, -6));
        cairo_line_to(cr, P(0, 6));
        arrow_head(cr, P(6, 0), 0, 2.4 * u);
        arrow_head(cr, P(-6, 0), G_PI, 2.4 * u);
        arrow_head(cr, P(0, 6), G_PI / 2, 2.4 * u);
        arrow_head(cr, P(0, -6), -G_PI / 2, 2.4 * u);
    } else if (!strcmp(k, "rotate")) {
        cairo_arc(cr, cx, cy, 5 * u, -G_PI / 2, G_PI);
        cairo_stroke(cr);
        arrow_head(cr, P(-5, 0), G_PI / 2, 2.6 * u);
    } else if (!strcmp(k, "scale")) {
        cairo_move_to(cr, P(-5, 5));
        cairo_line_to(cr, P(5, -5));
        cairo_move_to(cr, P(1, -5));
        cairo_line_to(cr, P(5, -5));
        cairo_line_to(cr, P(5, -1));
        cairo_move_to(cr, P(-5, 1));
        cairo_line_to(cr, P(-5, 5));
        cairo_line_to(cr, P(-1, 5));
    } else if (!strcmp(k, "add") || !strcmp(k, "remove")) {
        cairo_move_to(cr, P(-5, 0));
        cairo_line_to(cr, P(5, 0));
        if (!strcmp(k, "add")) {
            cairo_move_to(cr, P(0, -5));
            cairo_line_to(cr, P(0, 5));
        }
    } else if (!strcmp(k, "quality")) {
        for (int i = 0; i < 10; i++) {
            double a = -G_PI / 2 + i * G_PI / 5, rr = (i % 2 ? 2.6 : 6.0) * u;
            if (i == 0) cairo_move_to(cr, cx + rr * cos(a), cy + rr * sin(a));
            else cairo_line_to(cr, cx + rr * cos(a), cy + rr * sin(a));
        }
        cairo_close_path(cr);
        cairo_fill(cr);
        return;
    } else if (!strcmp(k, "printer")) {
        cairo_rectangle(cr, P(-6, -2), 12 * u, 6 * u);
        cairo_rectangle(cr, P(-3.5, -6), 7 * u, 4 * u);
        cairo_move_to(cr, P(-2, 5.5));
        cairo_line_to(cr, P(2, 5.5));
    } else if (!strcmp(k, "start")) {
        cairo_move_to(cr, P(-3, 6));
        cairo_line_to(cr, P(-3, -6));
        cairo_line_to(cr, P(5, -3.5));
        cairo_line_to(cr, P(-3, -1));
    } else {
        cairo_arc(cr, cx, cy, 2 * u, 0, 2 * G_PI);
        cairo_fill(cr);
        return;
    }
#undef P
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
static gboolean revertible(const char *line) {
    if (strstr(line, "\tquality\t")) return FALSE;
    if (!g_str_has_prefix(line, "part:")) return TRUE;
    const char *key = strchr(line, '\t');
    if (!key) return FALSE;
    key++;
    return !(g_str_has_prefix(key, "(part)") || g_str_has_prefix(key, "position") || g_str_has_prefix(key, "rotation") || g_str_has_prefix(key, "orientation") ||
             g_str_has_prefix(key, "scale"));
}

/* The changes of step i in words, as markup for a tooltip. */
static char *step_tooltip(ZgModel *model, guint i) {
    GString *s = g_string_new(NULL);
    char *t = step_time(zg_model_history_time(model, i));
    if (i == 0) g_string_append(s, "<b>Start</b>");
    else g_string_append_printf(s, "<b>Change %u · %s</b>", i, look_of(step_kind(model, i))->label);
    if (*t) g_string_append_printf(s, " · %s", t);
    g_free(t);
    if (i == zg_model_history_current(model)) g_string_append(s, " · now");
    char *changes = zg_model_history_changes(model, i);
    char *words = zg_model_history_describe(model, changes);
    char **lines = g_strsplit(words, "\n", -1);
    int n = 0;
    for (int k = 0; lines[k]; k++) {
        if (!*lines[k]) continue;
        char *tab = strchr(lines[k], '\t');
        if (!tab) continue;
        *tab = 0;
        char *scope = g_markup_escape_text(lines[k], -1), *change = g_markup_escape_text(tab + 1, -1);
        if (n < 8) g_string_append_printf(s, "\n%s · %s", change, scope);
        g_free(scope);
        g_free(change);
        n++;
    }
    if (n > 8) g_string_append_printf(s, "\n… and %d more", n - 8);
    if (n == 0 && i > 0) g_string_append(s, "\nOther changes");
    if (i != zg_model_history_current(model)) g_string_append(s, "\n<i>Click to go back to this change.</i>");
    g_strfreev(lines);
    g_free(words);
    g_free(changes);
    return g_string_free(s, FALSE);
}

/* ---- keys: the arrows go to the step before or after, and Space goes
 * back to the step shown before (to compare two steps) ---- */

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
    GtkWidget *stack; /* the page stack of the panel */
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
            gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "selected");
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
        GtkWidget *page = gtk_stack_get_child_by_name(GTK_STACK(p->stack), "settings");
        if (page) {
            gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "settings");
            zg_settings_browser_show_setting(page, key);
        }
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
    gtk_box_append(GTK_BOX(head), kind_badge(step_kind(p->model, i), 22));
    gtk_box_append(GTK_BOX(head), tl);
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
    if (n == 0) return;
    /* The newest first. */
    for (guint k = n; k-- > 0;) {
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), step_row(p, k));
        g_object_set_data(G_OBJECT(row), "zg-step", GUINT_TO_POINTER(k));
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
    /* After the click on the tab: its button takes the focus on the
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

GtkWidget *zg_history_page_new(ZgModel *model, GtkWidget *stack) {
    ensure_css();
    Page *p = g_new0(Page, 1);
    p->model = g_object_ref(model);
    p->stack = stack;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *help = gtk_label_new("Each change of the settings or of the plate, the newest first. "
                                    "Click a change to go back to it: the preview slices as it was then. "
                                    "↑ and ↓ go to the next change, and Space goes back to the one shown before, "
                                    "to compare two. A new edit there drops the later changes. "
                                    "↶ undoes only one setting and keeps the later changes. "
                                    "Double-click a setting to edit it.");
    gtk_label_set_wrap(GTK_LABEL(help), TRUE);
    gtk_label_set_xalign(GTK_LABEL(help), 0);
    gtk_widget_add_css_class(help, "dim-label");
    gtk_widget_set_margin_start(help, 10);
    gtk_widget_set_margin_end(help, 10);
    p->list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(p->list), GTK_SELECTION_NONE);
    gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(p->list), TRUE);
    gtk_widget_add_css_class(p->list, "navigation-sidebar");
    g_signal_connect(p->list, "row-activated", G_CALLBACK(on_row), p);
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
    gtk_widget_set_vexpand(p->scroller, TRUE);
    gtk_box_append(GTK_BOX(box), help);
    gtk_box_append(GTK_BOX(box), p->scroller);
    g_object_set_data_full(G_OBJECT(box), "zg-history", p, page_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_history), p);
    g_signal_connect(model, "core-event", G_CALLBACK(on_page_core), p);
    g_signal_connect(p->list, "map", G_CALLBACK(on_page_map), p);
    page_fill(p);
    return box;
}

/* ---- the timeline ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *steps, *scroller, *undo, *redo, *empty;
} Timeline;

static void on_step(GtkButton *b, gpointer data) {
    Timeline *t = data;
    go_step(t->model, GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "zg-step")));
}

/* Left: the older step, Right: the newer step, Space: the step shown
 * before. */
static gboolean on_timeline_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Timeline *t = data;
    gint64 cur = zg_model_history_current(t->model);
    switch (key) {
    case GDK_KEY_Left: case GDK_KEY_KP_Left: go_step(t->model, cur - 1); return TRUE;
    case GDK_KEY_Right: case GDK_KEY_KP_Right: go_step(t->model, cur + 1); return TRUE;
    case GDK_KEY_space: flip_step(t->model); return TRUE;
    default: return FALSE;
    }
}

static gboolean on_step_tooltip(GtkWidget *b, int x, int y, gboolean keyboard, GtkTooltip *tip, gpointer data) {
    Timeline *t = data;
    guint i = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "zg-step"));
    if (i >= zg_model_history_count(t->model)) return FALSE;
    char *markup = step_tooltip(t->model, i);
    gtk_tooltip_set_markup(tip, markup);
    g_free(markup);
    return TRUE;
}

static gboolean scroll_to_now(gpointer data) {
    Timeline *t = data;
    GtkAdjustment *adj = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(t->scroller));
    guint n = zg_model_history_count(t->model), now = zg_model_history_current(t->model);
    double f = n > 1 ? (double)now / (double)(n - 1) : 1;
    double page = gtk_adjustment_get_page_size(adj);
    double range = gtk_adjustment_get_upper(adj) - page;
    gtk_adjustment_set_value(adj, MAX(0, f * range));
    return G_SOURCE_REMOVE;
}

static void timeline_fill(Timeline *t) {
    GtkRoot *root = gtk_widget_get_root(t->steps);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    gboolean had_focus = focus && gtk_widget_is_ancestor(focus, t->steps);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(t->steps))) gtk_box_remove(GTK_BOX(t->steps), child);
    guint n = zg_model_history_count(t->model), now = zg_model_history_current(t->model);
    gtk_widget_set_visible(t->empty, n <= 1);
    for (guint i = 0; i < n; i++) {
        if (i > 0) {
            GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_add_css_class(line, "zg-tl-line");
            gtk_widget_set_valign(line, GTK_ALIGN_CENTER);
            gtk_box_append(GTK_BOX(t->steps), line);
        }
        GtkWidget *b = gtk_button_new();
        gtk_button_set_child(GTK_BUTTON(b), kind_badge(step_kind(t->model, i), i == now ? 22 : 18));
        gtk_widget_add_css_class(b, "zg-tl-step");
        if (i == now) gtk_widget_add_css_class(b, "zg-tl-now");
        else if (i > now) gtk_widget_add_css_class(b, "zg-tl-later");
        gtk_widget_set_valign(b, GTK_ALIGN_CENTER);
        /* The tooltip is made when it shows, so it has the layer numbers
         * of the last slice. */
        gtk_widget_set_has_tooltip(b, TRUE);
        g_signal_connect(b, "query-tooltip", G_CALLBACK(on_step_tooltip), t);
        g_object_set_data(G_OBJECT(b), "zg-step", GUINT_TO_POINTER(i));
        g_signal_connect(b, "clicked", G_CALLBACK(on_step), t);
        gtk_box_append(GTK_BOX(t->steps), b);
        if (i == now && had_focus) gtk_widget_grab_focus(b);
    }
    gtk_widget_set_sensitive(t->undo, now > 0);
    gtk_widget_set_sensitive(t->redo, now + 1 < n);
    g_idle_add(scroll_to_now, t);
}

static void on_timeline(ZgModel *model, gpointer data) {
    timeline_fill(data);
}

static void on_undo(GtkButton *b, gpointer data) {
    zg_model_undo(((Timeline *)data)->model);
}

static void on_redo(GtkButton *b, gpointer data) {
    zg_model_redo(((Timeline *)data)->model);
}

static void timeline_free(gpointer data) {
    Timeline *t = data;
    g_signal_handlers_disconnect_by_data(t->model, t);
    g_object_unref(t->model);
    g_free(t);
}

GtkWidget *zg_timeline_new(ZgModel *model) {
    ensure_css();
    Timeline *t = g_new0(Timeline, 1);
    t->model = g_object_ref(model);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(bar, "zg-timeline");
    t->undo = gtk_button_new_from_icon_name("edit-undo-symbolic");
    t->redo = gtk_button_new_from_icon_name("edit-redo-symbolic");
    gtk_widget_set_tooltip_text(t->undo, "Undo (Ctrl+Z)");
    gtk_widget_set_tooltip_text(t->redo, "Redo (Ctrl+Shift+Z)");
    for (int k = 0; k < 2; k++) gtk_widget_add_css_class(k ? t->redo : t->undo, "flat");
    g_signal_connect(t->undo, "clicked", G_CALLBACK(on_undo), t);
    g_signal_connect(t->redo, "clicked", G_CALLBACK(on_redo), t);
    GtkWidget *label = gtk_label_new("History");
    gtk_widget_add_css_class(label, "dim-label");
    gtk_widget_add_css_class(label, "caption");
    t->steps = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_valign(t->steps, GTK_ALIGN_CENTER);
    t->empty = gtk_label_new("Each change of the settings or the plate adds a mark here.");
    gtk_widget_add_css_class(t->empty, "dim-label");
    gtk_widget_add_css_class(t->empty, "caption");
    GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(inner), t->steps);
    gtk_box_append(GTK_BOX(inner), t->empty);
    t->scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(t->scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(t->scroller), inner);
    gtk_widget_set_hexpand(t->scroller, TRUE);
    gtk_box_append(GTK_BOX(bar), t->undo);
    gtk_box_append(GTK_BOX(bar), t->redo);
    gtk_box_append(GTK_BOX(bar), label);
    gtk_box_append(GTK_BOX(bar), t->scroller);
    GtkEventController *tk = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(tk, GTK_PHASE_CAPTURE);
    g_signal_connect(tk, "key-pressed", G_CALLBACK(on_timeline_key), t);
    gtk_widget_add_controller(bar, tk);
    g_object_set_data_full(G_OBJECT(bar), "zg-timeline", t, timeline_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_timeline), t);
    timeline_fill(t);
    return bar;
}
