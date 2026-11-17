/* cura-compare.c: see cura-compare.h.
 *
 * The window reads the Cura stack again at each refresh, so a change in
 * Cura shows after "Reload". A change in zslice (here or in the settings
 * panel) refreshes the rows at once.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "cura-compare.h"

#include "../prefs/cura-stack.h"

#include <math.h>
#include <string.h>

typedef struct {
    ZgModel *model;
    GtkWidget *window;
    GtkWidget *title;
    GtkWidget *summary;
    GtkWidget *show_all;
    GtkWidget *use_all;
    GtkWidget *scroll;
    guint refresh_idle;
    gboolean applying; /* "Use all" runs: one refresh at the end */
    char *error;       /* the last error of a "Use", or NULL */
} Compare;

static void refresh(Compare *c);

/* The information of a setting, or NULL. */
static gboolean setting_info(const char *name, zs_setting_info *out) {
    for (size_t i = 0; i < zs_setting_count(); i++) {
        if (zs_setting_get_info(i, out) == ZS_OK && strcmp(out->name, name) == 0) return TRUE;
    }
    return FALSE;
}

static const char *group_label(const char *name) {
    if (g_str_has_prefix(name, "machine.")) return "Printer";
    if (g_str_has_prefix(name, "filament.")) return "Filament";
    if (g_str_has_prefix(name, "project.")) return "This print";
    return "";
}

/* A value for people: with its unit, a ratio as a percentage, a speed
 * ratio with its mm/s, and the first line of a long text. */
static char *display_value(Compare *c, const zs_setting_info *info, const char *name, const char *value) {
    if (strchr(value, '\n')) {
        const char *nl = strchr(value, '\n');
        guint lines = 1;
        for (const char *p = value; *p; p++) lines += *p == '\n' && p[1] != 0;
        return g_strdup_printf("%.*s … (%u lines)", (int)(nl - value), value, lines);
    }
    if (!info || !info->unit || !info->unit[0]) return g_strdup(value[0] ? value : "(empty)");
    char *end = NULL;
    double v = g_ascii_strtod(value, &end);
    if (end == value) return g_strdup(value);
    if (strcmp(info->unit, "%") == 0) {
        double mm_s = 0;
        char pct[G_ASCII_DTOSTR_BUF_SIZE];
        g_ascii_formatd(pct, sizeof pct, "%.4g", v * 100);
        if (zs_app_ratio_speed(zg_model_core(c->model), name, value, &mm_s) == ZS_OK) {
            char speed[G_ASCII_DTOSTR_BUF_SIZE];
            g_ascii_formatd(speed, sizeof speed, "%.1f", mm_s);
            if (g_str_has_suffix(speed, ".0")) speed[strlen(speed) - 2] = 0;
            return g_strdup_printf("%s %% (%s mm/s)", pct, speed);
        }
        return g_strdup_printf("%s %%", pct);
    }
    return g_strdup_printf("%s %s", value, info->unit);
}

static GtkWidget *cell_label(const char *text, gboolean dim) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(l), 34);
    if (dim) {
        gtk_widget_add_css_class(l, "dim-label");
        gtk_widget_add_css_class(l, "caption");
    }
    return l;
}

/* A value and a line under it. */
static GtkWidget *cell_two(const char *text, const char *under, const char *tooltip) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    GtkWidget *top = cell_label(text, FALSE);
    gtk_widget_add_css_class(top, "numeric");
    gtk_box_append(GTK_BOX(box), top);
    if (under && under[0]) gtk_box_append(GTK_BOX(box), cell_label(under, TRUE));
    if (tooltip && tooltip[0]) gtk_widget_set_tooltip_text(box, tooltip);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    return box;
}

/* Sets one value of Cura. FALSE with c->error set if zslice refuses it. */
static gboolean use_value(Compare *c, const char *name, const char *value) {
    GError *error = NULL;
    if (zg_model_set(c->model, name, value, &error)) return TRUE;
    g_free(c->error);
    c->error = g_strdup_printf("%s: %s", name, error ? error->message : "zslice refuses the value");
    g_clear_error(&error);
    return FALSE;
}

static void on_use(GtkButton *button, gpointer data) {
    Compare *c = data;
    g_clear_pointer(&c->error, g_free);
    use_value(c, g_object_get_data(G_OBJECT(button), "zg-name"), g_object_get_data(G_OBJECT(button), "zg-value"));
    refresh(c);
}

/* Runs a comparison. NULL with a message in *error on an error. */
static zs_cura_compare *run(Compare *c, char **title, char **error) {
    GError *gerr = NULL;
    ZgCuraStack *stack = zg_cura_stack_find(&gerr);
    if (!stack) {
        *error = g_strdup(gerr->message);
        g_error_free(gerr);
        return NULL;
    }
    *title = g_strdup(zg_cura_stack_title(stack));
    zs_cura_compare *cc = NULL;
    char message[512] = "";
    int rc = zs_app_cura_compare(zg_model_core(c->model), zg_cura_stack_read, stack, &cc, message, sizeof message);
    zg_cura_stack_free(stack);
    if (rc != ZS_OK) {
        *error = g_strdup_printf("zslice cannot read the Cura stack: %s", message[0] ? message : "error");
        return NULL;
    }
    return cc;
}

/* "Use all": the max speed first, because the speed ratios of Cura relate
 * to it; then a new comparison, and each value that differs. */
static void on_use_all(GtkButton *button, gpointer data) {
    Compare *c = data;
    g_clear_pointer(&c->error, g_free);
    c->applying = TRUE;
    for (int pass = 0; pass < 2; pass++) {
        char *title = NULL, *error = NULL;
        zs_cura_compare *cc = run(c, &title, &error);
        g_free(title);
        if (!cc) {
            c->error = error;
            break;
        }
        for (size_t i = 0; i < zs_cura_compare_count(cc); i++) {
            zs_cura_row r;
            if (zs_cura_compare_get(cc, i, &r) != ZS_OK || !r.in_use_all) continue;
            gboolean max_speed = strcmp(r.name, "machine.max_speed") == 0;
            if (pass == 0 && !max_speed) continue;
            use_value(c, r.name, r.cura_value);
        }
        zs_cura_compare_free(cc);
    }
    c->applying = FALSE;
    refresh(c);
}

static void add_header(GtkWidget *grid, int col, const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_add_css_class(l, "heading");
    gtk_grid_attach(GTK_GRID(grid), l, col, 0, 1, 1);
}

static void refresh(Compare *c) {
    char *title = NULL, *error = NULL;
    zs_cura_compare *cc = run(c, &title, &error);
    gtk_label_set_text(GTK_LABEL(c->title), title ? title : "Cura");
    g_free(title);
    if (!cc) {
        gtk_label_set_text(GTK_LABEL(c->summary), error);
        g_free(error);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(c->scroll), NULL);
        gtk_widget_set_sensitive(c->use_all, FALSE);
        return;
    }
    gboolean all = gtk_check_button_get_active(GTK_CHECK_BUTTON(c->show_all));

    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 18);
    gtk_widget_set_margin_start(grid, 16);
    gtk_widget_set_margin_end(grid, 16);
    gtk_widget_set_margin_top(grid, 10);
    gtk_widget_set_margin_bottom(grid, 16);
    add_header(grid, 0, "Setting");
    add_header(grid, 1, "Group");
    add_header(grid, 2, "zslice");
    add_header(grid, 3, "Cura");

    size_t n = zs_cura_compare_count(cc), differ = 0, take = 0, formulas = 0;
    int row = 1;
    for (size_t i = 0; i < n; i++) {
        zs_cura_row r;
        if (zs_cura_compare_get(cc, i, &r) != ZS_OK) continue;
        differ += r.differs != 0;
        take += r.in_use_all != 0;
        formulas += r.formula != 0;
        if (!all && !r.differs) continue;
        zs_setting_info info;
        gboolean known = setting_info(r.name, &info);

        char *keys = r.cura_keys[0] ? g_strdup_printf("Cura: %s", r.cura_keys) : g_strdup("");
        GtkWidget *name_cell = cell_two(known ? info.label : r.name, keys, r.name);
        g_free(keys);
        gtk_widget_set_hexpand(name_cell, TRUE);
        gtk_grid_attach(GTK_GRID(grid), name_cell, 0, row, 1, 1);
        GtkWidget *group = cell_label(group_label(r.name), FALSE);
        gtk_widget_set_valign(group, GTK_ALIGN_CENTER);
        gtk_grid_attach(GTK_GRID(grid), group, 1, row, 1, 1);

        char *zv = display_value(c, known ? &info : NULL, r.name, r.zslice_value);
        gtk_grid_attach(GTK_GRID(grid), cell_two(zv, NULL, strchr(r.zslice_value, '\n') ? r.zslice_value : NULL), 2, row, 1, 1);
        g_free(zv);

        char *cv = r.formula ? g_strdup(r.cura_value) : display_value(c, known ? &info : NULL, r.name, r.cura_value);
        const char *under = r.formula ? "A formula: zslice cannot take it."
                            : (r.differs && !r.in_use_all) ? "Not in \"Use all\"."
                                                           : r.note;
        char *from = g_path_get_basename(r.from);
        gboolean long_text = strchr(r.cura_value, '\n') != NULL;
        char *tip = g_strdup_printf("%s%s%s%sFrom %s", long_text ? r.cura_value : "", long_text ? "\n\n" : "", r.note,
                                    r.note[0] ? ".\n" : "", from);
        GtkWidget *cura_cell = cell_two(cv, under, tip);
        if (r.differs) gtk_widget_add_css_class(gtk_widget_get_first_child(cura_cell), "accent");
        gtk_grid_attach(GTK_GRID(grid), cura_cell, 3, row, 1, 1);
        g_free(cv);
        g_free(from);
        g_free(tip);

        GtkWidget *use = gtk_button_new_with_label("Use");
        gtk_widget_set_valign(use, GTK_ALIGN_CENTER);
        gtk_widget_set_sensitive(use, r.differs && !r.formula);
        gtk_widget_set_tooltip_text(use, "Set the value of Cura in zslice.");
        g_object_set_data_full(G_OBJECT(use), "zg-name", g_strdup(r.name), g_free);
        g_object_set_data_full(G_OBJECT(use), "zg-value", g_strdup(r.cura_value), g_free);
        g_signal_connect(use, "clicked", G_CALLBACK(on_use), c);
        gtk_grid_attach(GTK_GRID(grid), use, 4, row, 1, 1);
        row++;
    }
    zs_cura_compare_free(cc);
    if (row == 1) {
        GtkWidget *same = gtk_label_new("zslice and Cura have the same values for all mapped settings.");
        gtk_widget_add_css_class(same, "dim-label");
        gtk_widget_set_margin_top(same, 24);
        gtk_grid_attach(GTK_GRID(grid), same, 0, 1, 5, 1);
    }
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(c->scroll), grid);

    GString *s = g_string_new(NULL);
    g_string_printf(s, "%zu of %zu mapped settings differ.", differ, n - formulas);
    if (formulas) g_string_append_printf(s, " %zu Cura values are formulas.", formulas);
    if (c->error) g_string_append_printf(s, "\n%s", c->error);
    gtk_label_set_text(GTK_LABEL(c->summary), s->str);
    g_string_free(s, TRUE);
    char *label = g_strdup_printf("Use all (%zu)", take);
    gtk_button_set_label(GTK_BUTTON(c->use_all), label);
    g_free(label);
    gtk_widget_set_sensitive(c->use_all, take > 0);
}

static gboolean refresh_idle(gpointer data) {
    Compare *c = data;
    c->refresh_idle = 0;
    refresh(c);
    return G_SOURCE_REMOVE;
}

/* A setting changed (here, in the panel, or by Undo). */
static void on_setting_changed(ZgModel *model, const char *key, gpointer data) {
    Compare *c = data;
    if (c->applying || c->refresh_idle) return;
    c->refresh_idle = g_idle_add(refresh_idle, c);
}

static void on_reload(GtkButton *button, gpointer data) {
    Compare *c = data;
    g_clear_pointer(&c->error, g_free);
    refresh(c);
}

static void on_toggle(GtkCheckButton *check, gpointer data) {
    refresh(data);
}

static void compare_free(gpointer data) {
    Compare *c = data;
    if (c->refresh_idle) g_source_remove(c->refresh_idle);
    g_signal_handlers_disconnect_by_data(c->model, c);
    g_object_unref(c->model);
    g_free(c->error);
    g_free(c);
}

void zg_cura_compare_show(GtkWindow *parent, ZgModel *model, gboolean show_all) {
    Compare *c = g_new0(Compare, 1);
    c->model = g_object_ref(model);
    GtkWidget *win = gtk_window_new();
    c->window = win;
    gtk_window_set_title(GTK_WINDOW(win), "Compare with Cura");
    gtk_window_set_transient_for(GTK_WINDOW(win), parent);
    gtk_window_set_default_size(GTK_WINDOW(win), 980, 680);
    g_object_set_data_full(G_OBJECT(win), "zg-cura-compare", c, compare_free);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(top, 16);
    gtk_widget_set_margin_end(top, 16);
    gtk_widget_set_margin_top(top, 12);
    gtk_widget_set_margin_bottom(top, 10);
    c->title = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->title), 0);
    gtk_label_set_wrap(GTK_LABEL(c->title), TRUE);
    gtk_widget_add_css_class(c->title, "title-4");
    c->summary = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->summary), 0);
    gtk_label_set_wrap(GTK_LABEL(c->summary), TRUE);
    gtk_widget_add_css_class(c->summary, "dim-label");
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    c->show_all = gtk_check_button_new_with_label("Show all mapped settings");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c->show_all), show_all);
    gtk_widget_set_hexpand(c->show_all, TRUE);
    GtkWidget *reload = gtk_button_new_with_label("Reload");
    gtk_widget_set_tooltip_text(reload, "Read the settings of Cura again.");
    c->use_all = gtk_button_new_with_label("Use all");
    gtk_widget_add_css_class(c->use_all, "suggested-action");
    gtk_widget_set_tooltip_text(c->use_all, "Set each value of Cura that differs in zslice. The names and the start and "
                                            "end G-code stay as they are.");
    gtk_box_append(GTK_BOX(bar), c->show_all);
    gtk_box_append(GTK_BOX(bar), reload);
    gtk_box_append(GTK_BOX(bar), c->use_all);
    gtk_box_append(GTK_BOX(top), c->title);
    gtk_box_append(GTK_BOX(top), c->summary);
    gtk_box_append(GTK_BOX(top), bar);
    gtk_box_append(GTK_BOX(box), top);
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    c->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(c->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(c->scroll, TRUE);
    gtk_box_append(GTK_BOX(box), c->scroll);
    gtk_window_set_child(GTK_WINDOW(win), box);

    g_signal_connect(c->show_all, "toggled", G_CALLBACK(on_toggle), c);
    g_signal_connect(reload, "clicked", G_CALLBACK(on_reload), c);
    g_signal_connect(c->use_all, "clicked", G_CALLBACK(on_use_all), c);
    g_signal_connect(model, "setting-changed", G_CALLBACK(on_setting_changed), c);
    refresh(c);
    gtk_window_present(GTK_WINDOW(win));
    /* A test hook: ZSLICE_CURA_COMPARE=use-all presses "Use all". */
    if (g_strcmp0(g_getenv("ZSLICE_CURA_COMPARE"), "use-all") == 0) gtk_widget_activate(c->use_all);
}
