/* widgets.c: see widgets.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <string.h>
#include "widgets.h"

GtkWidget *zg_grid_new(void) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    gtk_widget_set_margin_start(grid, 12);
    gtk_widget_set_margin_end(grid, 12);
    gtk_widget_set_margin_top(grid, 12);
    gtk_widget_set_margin_bottom(grid, 12);
    return grid;
}

GtkWidget *zg_grid_add_heading(GtkWidget *grid, int *row, const char *text) {
    GtkWidget *heading = gtk_label_new(text);
    gtk_widget_add_css_class(heading, "heading");
    gtk_widget_set_halign(heading, GTK_ALIGN_START);
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_label_set_wrap(GTK_LABEL(heading), TRUE);
    gtk_widget_set_margin_top(heading, *row == 0 ? 0 : 12);
    gtk_grid_attach(GTK_GRID(grid), heading, 0, (*row)++, 3, 1);
    return heading;
}

GtkWidget *zg_scrolled_new(GtkWidget *child) {
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), child);
    gtk_widget_set_vexpand(scroll, TRUE);
    return scroll;
}

GtkWidget *zg_wrapped_label_new(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_set_hexpand(l, TRUE);
    return l;
}

const char *zg_doc_plain(const char *doc) {
    if (!doc || !strchr(doc, '`')) return doc ? doc : "";
    GString *s = g_string_new(NULL);
    for (const char *c = doc; *c; c++)
        if (*c != '`') g_string_append_c(s, *c);
    const char *out = g_intern_string(s->str);
    g_string_free(s, TRUE);
    return out;
}

GtkWidget *zg_doc_label_new(const char *doc) {
    GtkWidget *l = zg_wrapped_label_new(NULL);
    GString *m = g_string_new(NULL);
    gboolean code = FALSE;
    const char *c = doc ? doc : "";
    while (*c) {
        const char *next = strchr(c, '`');
        size_t n = next ? (size_t)(next - c) : strlen(c);
        char *esc = g_markup_escape_text(c, (gssize)n);
        if (code) g_string_append_printf(m, "<tt>%s</tt>", esc);
        else g_string_append(m, esc);
        g_free(esc);
        if (!next) break;
        code = !code;
        c = next + 1;
    }
    gtk_label_set_markup(GTK_LABEL(l), m->str);
    g_string_free(m, TRUE);
    return l;
}

gboolean zg_theme_dark(GtkWidget *widget) {
    GdkRGBA c;
    gtk_widget_get_color(widget, &c);
    return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue > 0.5;
}

typedef struct {
    GtkWidget *owner;
    void (*fn)(gpointer);
    gpointer data;
    guint idle;
} ThemeWatch;

static gboolean theme_idle(gpointer data) {
    ThemeWatch *t = data;
    t->idle = 0;
    t->fn(t->data);
    return G_SOURCE_REMOVE;
}

static void on_theme_setting(GObject *settings, GParamSpec *pspec, gpointer data) {
    ThemeWatch *t = data;
    /* The style of the widgets changes after this signal: read it later. */
    if (!t->idle) t->idle = g_timeout_add(60, theme_idle, t);
}

static void theme_watch_free(gpointer data) {
    ThemeWatch *t = data;
    GtkSettings *s = gtk_settings_get_default();
    if (s) g_signal_handlers_disconnect_by_data(s, t);
    if (t->idle) g_source_remove(t->idle);
    g_free(t);
}

void zg_on_theme_changed(GtkWidget *owner, void (*fn)(gpointer), gpointer data) {
    GtkSettings *s = gtk_settings_get_default();
    if (!s) return;
    ThemeWatch *t = g_new0(ThemeWatch, 1);
    t->owner = owner;
    t->fn = fn;
    t->data = data;
    static const char *props[] = {"gtk-interface-color-scheme", "gtk-application-prefer-dark-theme", "gtk-theme-name"};
    for (size_t i = 0; i < G_N_ELEMENTS(props); i++) {
        if (!g_object_class_find_property(G_OBJECT_GET_CLASS(s), props[i])) continue;
        char *sig = g_strconcat("notify::", props[i], NULL);
        g_signal_connect(s, sig, G_CALLBACK(on_theme_setting), t);
        g_free(sig);
    }
    g_object_set_data_full(G_OBJECT(owner), "zg-theme-watch", t, theme_watch_free);
}
