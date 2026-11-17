/* history.c: see history.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "history.h"

#include <string.h>

static const char *css =
    ".zg-history-step { padding: 8px 10px; }\n"
    ".zg-history-now { background: alpha(@accent_bg_color, 0.18); border-left: 3px solid @accent_bg_color; }\n"
    ".zg-history-later { opacity: 0.55; }\n"
    ".zg-history-badge { font-size: 0.8em; font-weight: bold; padding: 0 6px; border-radius: 8px;"
    " background: @accent_bg_color; color: @accent_fg_color; }\n"
    ".zg-timeline { padding: 3px 8px; border-top: 1px solid alpha(currentColor, 0.15); }\n"
    ".zg-tl-step { min-width: 14px; min-height: 14px; padding: 0; margin: 0 2px; border-radius: 7px;"
    " background: alpha(currentColor, 0.35); }\n"
    ".zg-tl-step:hover { background: alpha(currentColor, 0.7); }\n"
    ".zg-tl-step.zg-tl-now { background: @accent_bg_color; min-width: 18px; min-height: 18px; border-radius: 9px; }\n"
    ".zg-tl-step.zg-tl-later { background: alpha(currentColor, 0.15); }\n"
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
    if (!g_str_has_prefix(line, "part:")) return TRUE;
    const char *key = strchr(line, '\t');
    if (!key) return FALSE;
    key++;
    return !(g_str_has_prefix(key, "(part)") || g_str_has_prefix(key, "position") || g_str_has_prefix(key, "rotation") ||
             g_str_has_prefix(key, "scale"));
}

/* The changes of step i in words, as markup for a tooltip. */
static char *step_tooltip(ZgModel *model, guint i) {
    GString *s = g_string_new(NULL);
    char *t = step_time(zg_model_history_time(model, i));
    if (i == 0) g_string_append(s, "<b>Start</b>");
    else g_string_append_printf(s, "<b>Step %u</b>", i);
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
    if (i != zg_model_history_current(model)) g_string_append(s, "\n<i>Click to go to this step.</i>");
    g_strfreev(lines);
    g_free(words);
    g_free(changes);
    return g_string_free(s, FALSE);
}

/* ---- the History page ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *list;
    GtkWidget *scroller;
} Page;

static void on_revert(GtkButton *b, gpointer data) {
    Page *p = data;
    const char *line = g_object_get_data(G_OBJECT(b), "zg-change");
    if (line) zg_model_history_revert(p->model, line);
}

static GtkWidget *change_row(Page *p, const char *scope, const char *words, const char *line, gboolean can_undo) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
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
    char *title = i == 0 ? g_strdup("Start") : g_strdup_printf("Step %u", i);
    GtkWidget *tl = gtk_label_new(title);
    gtk_widget_add_css_class(tl, "heading");
    gtk_label_set_xalign(GTK_LABEL(tl), 0);
    GtkWidget *tt = gtk_label_new(t);
    gtk_widget_add_css_class(tt, "dim-label");
    gtk_widget_add_css_class(tt, "numeric");
    gtk_widget_set_hexpand(tt, TRUE);
    gtk_label_set_xalign(GTK_LABEL(tt), 0);
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
        gtk_box_append(GTK_BOX(box), change_row(p, wl[k], tab + 1, cl[k], can));
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

static void page_fill(Page *p) {
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
    }
}

static void on_row(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    Page *p = data;
    guint i = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(row), "zg-step"));
    zg_model_history_goto(p->model, i);
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

GtkWidget *zg_history_page_new(ZgModel *model) {
    ensure_css();
    Page *p = g_new0(Page, 1);
    p->model = g_object_ref(model);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *help = gtk_label_new("Each step is a change of the settings or of the plate, the newest first. "
                                    "Click a step to go back to it: the preview slices at that step. "
                                    "A new change there drops the later steps. ↶ undoes only one change.");
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
    p->scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(p->scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(p->scroller), p->list);
    gtk_widget_set_vexpand(p->scroller, TRUE);
    gtk_box_append(GTK_BOX(box), help);
    gtk_box_append(GTK_BOX(box), p->scroller);
    g_object_set_data_full(G_OBJECT(box), "zg-history", p, page_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_history), p);
    g_signal_connect(model, "core-event", G_CALLBACK(on_page_core), p);
    g_signal_connect_swapped(p->list, "map", G_CALLBACK(page_fill), p);
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
    zg_model_history_goto(t->model, GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "zg-step")));
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
    t->empty = gtk_label_new("Each change of the settings or the plate adds a step here.");
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
    g_object_set_data_full(G_OBJECT(bar), "zg-timeline", t, timeline_free);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_timeline), t);
    timeline_fill(t);
    return bar;
}
