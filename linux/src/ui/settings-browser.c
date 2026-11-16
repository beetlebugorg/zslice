/* settings-browser.c: see settings-browser.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-browser.h"

#include "colors.h"
#include "setting-editor.h"
#include "setting-row.h"
#include "widgets.h"

#include <math.h>
#include <string.h>

/* The groups of settings, in the order of the browser, with their titles. */
static const struct {
    const char *group;
    const char *title;
} groups[] = {
    {"project", "Project"},
    {"filament", "Filament"},
    {"machine", "Machine"},
    {"engine", "Engine"},
};

typedef struct {
    ZgModel *model;
    GtkWidget *page;     /* the Settings page of the panel stack */
    GtkWidget *hscroll;  /* the columns */
    GtkWidget *search;
    GtkWidget *sections; /* column 1 */
    GtkWidget *settings; /* column 2 */
    GtkWidget *detail;   /* column 3: a box; its child is rebuilt */
    GtkWidget *effect;   /* in column 3: the lines of the project */
    const char *key;     /* the selected setting, or NULL */
    GtkWidget *stack;    /* the page stack of the panel */
    guint32 focus;       /* the focus of the previews for the selection */
    gboolean focus_first;
    guint scroll_tick;
    int scroll_frames;   /* frames since the scroll started */
    /* The navigation bar: the column in front (0 sections, 1 settings,
     * 2 the setting), a Back button, and the path. */
    int column;
    GtkWidget *back;
    GtkWidget *crumbs;
    const char *group;   /* the selected section */
    const char *section;
    int feature;         /* the feature whose settings column 2 lists, or -1 */
} Browser;

enum { COL1_WIDTH = 165, COL2_WIDTH = 235, COL3_WIDTH = 300 };

static const char *feature_titles[] = {"Outer wall", "Inner wall", "Skin", "Sparse infill",
                                       "Ironing", "Skirt or brim", "Support", "Support interface",
                                       "Seams", "Travel moves", "Retractions"};
enum { N_MARKS = 3 };

static const char *group_title(const char *group) {
    for (size_t i = 0; i < G_N_ELEMENTS(groups); i++) {
        if (strcmp(groups[i].group, group) == 0) return groups[i].title;
    }
    return group;
}

/* The scroll that shows column c: all of it, at the right edge for a step
 * forward (the column before it stays in view, as far as it fits), and at
 * the left edge for a step back. */
static double column_goal(Browser *b, GtkAdjustment *adj) {
    double page = gtk_adjustment_get_page_size(adj);
    double max = gtk_adjustment_get_upper(adj) - page;
    double left[3] = {0, COL1_WIDTH + 1, COL1_WIDTH + COL2_WIDTH + 2};
    double right[3] = {COL1_WIDTH, COL1_WIDTH + COL2_WIDTH + 1, gtk_adjustment_get_upper(adj)};
    int c = b->column;
    double now = gtk_adjustment_get_value(adj);
    double goal = now;
    if (right[c] > now + page) goal = right[c] - page;
    if (left[c] < goal) goal = left[c];
    return CLAMP(goal, 0, MAX(max, 0));
}

/* Animates the columns to show the column in front. */
static gboolean on_scroll_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    Browser *b = data;
    GtkAdjustment *adj = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(b->hscroll));
    double goal = column_goal(b, adj);
    double now = gtk_adjustment_get_value(adj);
    /* The width of new content is known only after a layout: wait a few
     * frames before the scroll can end. */
    b->scroll_frames++;
    if (fabs(goal - now) < 1 && b->scroll_frames > 3) {
        gtk_adjustment_set_value(adj, goal);
        b->scroll_tick = 0;
        return G_SOURCE_REMOVE;
    }
    gtk_adjustment_set_value(adj, now + (goal - now) * 0.25);
    return G_SOURCE_CONTINUE;
}

static void update_crumbs(Browser *b);
static void on_feature_clicked(GtkButton *button, gpointer data);

static void show_column(Browser *b, int c) {
    b->column = CLAMP(c, 0, 2);
    b->scroll_frames = 0;
    if (!b->scroll_tick) b->scroll_tick = gtk_widget_add_tick_callback(b->hscroll, on_scroll_tick, b, NULL);
    update_crumbs(b);
}

static void scroll_to_end(Browser *b) {
    show_column(b, 2);
}

static void on_back(GtkButton *button, gpointer data) {
    Browser *b = data;
    show_column(b, b->column - 1);
}

static void on_crumb(GtkButton *button, gpointer data) {
    Browser *b = data;
    show_column(b, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "zg-column")));
}

static void add_crumb(Browser *b, const char *text, int column) {
    if (gtk_widget_get_first_child(b->crumbs)) {
        GtkWidget *sep = gtk_label_new("›");
        gtk_widget_add_css_class(sep, "dim-label");
        gtk_box_append(GTK_BOX(b->crumbs), sep);
    }
    GtkWidget *crumb = gtk_button_new_with_label(text);
    gtk_widget_add_css_class(crumb, "flat");
    gtk_widget_add_css_class(crumb, "zg-crumb");
    GtkWidget *label = gtk_button_get_child(GTK_BUTTON(crumb));
    if (GTK_IS_LABEL(label)) gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    g_object_set_data(G_OBJECT(crumb), "zg-column", GINT_TO_POINTER(column));
    if (column == b->column) gtk_widget_add_css_class(crumb, "zg-crumb-here");
    g_signal_connect(crumb, "clicked", G_CALLBACK(on_crumb), b);
    gtk_box_append(GTK_BOX(b->crumbs), crumb);
}

/* The path: Settings, the section (with its group), and the setting. */
static void update_crumbs(Browser *b) {
    if (!b->crumbs) return;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(b->crumbs))) gtk_box_remove(GTK_BOX(b->crumbs), child);
    add_crumb(b, "Settings", 0);
    if (b->section) {
        char *text = g_strdup_printf("%s · %s", group_title(b->group), b->section[0] ? b->section : "General");
        add_crumb(b, text, 1);
        g_free(text);
    } else if (b->feature >= 0) {
        char *text = g_strdup_printf("%s lines", feature_titles[b->feature]);
        add_crumb(b, text, 1);
        g_free(text);
    } else if (gtk_editable_get_text(GTK_EDITABLE(b->search))[0]) {
        add_crumb(b, "Search", 1);
    }
    zs_setting_info info;
    if (b->key && zg_setting_find(b->key, &info)) add_crumb(b, info.label, 2);
    gtk_widget_set_sensitive(b->back, b->column > 0);
}

/* Sends the focus to the previews, only while the Settings page shows. */
static void send_focus(Browser *b) {
    gboolean visible = b->stack && gtk_stack_get_visible_child(GTK_STACK(b->stack)) == b->page;
    zg_model_set_focus(b->model, visible ? b->focus : 0, b->focus_first);
}

/* The focus for a setting: the lines and marks that it changes. A setting
 * with no visible effect shows all lines in their feature colors, so a
 * selection always changes the view. */
static guint32 focus_of(const char *key, gboolean *first_only) {
    zs_setting_effect e = {0};
    zs_setting_get_effect(key, &e);
    *first_only = e.first_layer_only;
    return e.features ? e.features : (1u << ZS_FEATURE_COUNT) - 1;
}

/* The focus for a section: all lines and marks that its settings change. */
static guint32 section_focus(const char *group, const char *section) {
    guint32 mask = 0;
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK) continue;
        if (g_strcmp0(info.group, group) != 0 || g_strcmp0(info.section, section) != 0) continue;
        zs_setting_effect e = {0};
        zs_setting_get_effect(info.name, &e);
        mask |= e.features;
    }
    return mask ? mask : (1u << ZS_FEATURE_COUNT) - 1;
}

/* ---- column 3 ---- */

static void fill_effect(Browser *b) {
    if (!b->effect || !b->key) return;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(b->effect))) gtk_box_remove(GTK_BOX(b->effect), child);
    zs_setting_effect e = {0};
    zs_setting_get_effect(b->key, &e);
    if (e.features == 0) {
        char *text = g_strdup_printf("%s The preview shows all lines, in their feature colors.", e.note && e.note[0] ? e.note : "It changes no line.");
        GtkWidget *l = zg_wrapped_label_new(text);
        g_free(text);
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(b->effect), l);
        return;
    }
    zs_feature_stats stats[ZS_FEATURE_COUNT];
    gboolean have = zs_app_feature_stats(zg_model_core(b->model), stats) == ZS_OK;
    double total = 0;
    if (have) for (int f = 0; f < ZS_FEATURE_COUNT; f++) total += stats[f].time_s;
    GtkWidget *intro = zg_wrapped_label_new(e.first_layer_only ? "It changes these lines on the first layer:" : "It changes these lines:");
    gtk_box_append(GTK_BOX(b->effect), intro);
    int shown = 0;
    for (int f = 0; f < ZS_FEATURE_COUNT + N_MARKS; f++) {
        if (!((e.features >> f) & 1)) continue;
        if (f < ZS_FEATURE_COUNT && have && stats[f].paths == 0) continue;
        const double *rgb = f < ZS_FEATURE_COUNT ? zg_feature_rgb[f] : zg_mark_rgb[f - ZS_FEATURE_COUNT];
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        char *dot = g_strdup_printf("<span foreground=\"#%02x%02x%02x\">●</span>", (int)(rgb[0] * 255),
                                    (int)(rgb[1] * 255), (int)(rgb[2] * 255));
        GtkWidget *d = gtk_label_new(NULL);
        gtk_label_set_markup(GTK_LABEL(d), dot);
        g_free(dot);
        GtkWidget *name = gtk_label_new(feature_titles[f]);
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        gtk_widget_set_hexpand(name, TRUE);
        gtk_box_append(GTK_BOX(row), d);
        gtk_box_append(GTK_BOX(row), name);
        if (f < ZS_FEATURE_COUNT && have && total > 0 && !e.first_layer_only) {
            char buf[64];
            double min = stats[f].time_s / 60;
            g_snprintf(buf, sizeof buf, "%.0f min · %.0f %%", min, 100 * stats[f].time_s / total);
            GtkWidget *t = gtk_label_new(buf);
            gtk_widget_add_css_class(t, "dim-label");
            gtk_widget_add_css_class(t, "numeric");
            gtk_box_append(GTK_BOX(row), t);
        }
        /* A click on the row lists the settings of these lines. */
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "flat");
        gtk_widget_add_css_class(button, "zg-feature-row");
        gtk_button_set_child(GTK_BUTTON(button), row);
        char *tip = g_strdup_printf("Show all settings that change the %s lines", feature_titles[f]);
        gtk_widget_set_tooltip_text(button, tip);
        g_free(tip);
        g_object_set_data(G_OBJECT(button), "zg-feature", GINT_TO_POINTER(f));
        g_signal_connect(button, "clicked", G_CALLBACK(on_feature_clicked), b);
        gtk_box_append(GTK_BOX(b->effect), button);
        shown++;
    }
    if (shown == 0) {
        GtkWidget *l = zg_wrapped_label_new("This part has none of these lines now.");
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(b->effect), l);
    } else {
        GtkWidget *hint = zg_wrapped_label_new("The preview shows these lines, and the other lines fade.");
        gtk_widget_add_css_class(hint, "zg-note-plain");
        gtk_box_append(GTK_BOX(b->effect), hint);
    }
}

/* The default line and the reset button follow the value. */
static void show_default(GtkWidget *box) {
    const zs_setting_info *info = g_object_get_data(G_OBJECT(box), "zg-info");
    ZgModel *model = g_object_get_data(G_OBJECT(box), "zg-model");
    GtkWidget *label = g_object_get_data(G_OBJECT(box), "zg-label");
    GtkWidget *reset = g_object_get_data(G_OBJECT(box), "zg-reset");
    char *value = zg_model_get(model, info->name);
    gboolean same = strcmp(value, info->default_value) == 0 ||
                    (zg_parses_as_number(value) && zg_parses_as_number(info->default_value) &&
                     g_ascii_strtod(value, NULL) == g_ascii_strtod(info->default_value, NULL));
    char *def = zg_setting_value_with_unit(info, info->default_value);
    char *text = g_strdup_printf(same ? "The default (%s)" : "Default: %s", def);
    gtk_label_set_text(GTK_LABEL(label), text);
    g_free(text);
    g_free(def);
    g_free(value);
    /* The button keeps its space, so the help text does not move. */
    gtk_widget_set_opacity(reset, same ? 0 : 1);
    gtk_widget_set_sensitive(reset, !same);
}

static void on_default_setting_changed(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *box = data;
    const zs_setting_info *info = g_object_get_data(G_OBJECT(box), "zg-info");
    if (strcmp(key, info->name) == 0) show_default(box);
}

static void on_reset(GtkButton *button, gpointer data) {
    GtkWidget *box = data;
    const zs_setting_info *info = g_object_get_data(G_OBJECT(box), "zg-info");
    ZgModel *model = g_object_get_data(G_OBJECT(box), "zg-model");
    zg_model_set(model, info->name, info->default_value, NULL);
}

static void free_info(gpointer data) {
    g_free(data);
}

static void show_detail(Browser *b, const char *key) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(b->detail))) gtk_box_remove(GTK_BOX(b->detail), child);
    b->effect = NULL;
    b->key = NULL;
    zs_setting_info *info = g_new(zs_setting_info, 1);
    if (!key || !zg_setting_find(key, info)) {
        g_free(info);
        GtkWidget *hint = zg_wrapped_label_new("Pick a setting to see what it does and which lines of the project it changes.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_widget_set_margin_start(hint, 12);
        gtk_widget_set_margin_end(hint, 12);
        gtk_widget_set_margin_top(hint, 12);
        gtk_box_append(GTK_BOX(b->detail), hint);
        /* The focus of the section stays. */
        return;
    }
    b->key = info->name;
    GtkWidget *grid = zg_grid_new();
    int row = 0;
    GtkWidget *title = zg_grid_add_heading(grid, &row, info->label);
    gtk_widget_add_css_class(title, "title-4");
    char *where = g_strdup_printf("%s › %s", group_title(info->group), info->section);
    GtkWidget *path = zg_wrapped_label_new(where);
    g_free(where);
    gtk_widget_add_css_class(path, "dim-label");
    gtk_widget_add_css_class(path, "caption");
    gtk_grid_attach(GTK_GRID(grid), path, 0, row++, 3, 1);
    zg_setting_row_free(zg_setting_row_add(grid, &row, b->model, info, 0));

    GtkWidget *def = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *def_label = gtk_label_new("");
    gtk_widget_add_css_class(def_label, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(def_label), 0);
    gtk_label_set_wrap(GTK_LABEL(def_label), TRUE);
    gtk_widget_set_hexpand(def_label, TRUE);
    GtkWidget *reset = gtk_button_new_with_label("Reset");
    gtk_widget_add_css_class(reset, "flat");
    gtk_widget_set_valign(reset, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(def), def_label);
    gtk_box_append(GTK_BOX(def), reset);
    g_object_set_data_full(G_OBJECT(def), "zg-info", info, free_info);
    g_object_set_data(G_OBJECT(def), "zg-model", b->model);
    g_object_set_data(G_OBJECT(def), "zg-label", def_label);
    g_object_set_data(G_OBJECT(def), "zg-reset", reset);
    g_signal_connect(reset, "clicked", G_CALLBACK(on_reset), def);
    g_signal_connect_object(b->model, "setting-changed", G_CALLBACK(on_default_setting_changed), def, 0);
    show_default(def);
    gtk_grid_attach(GTK_GRID(grid), def, 0, row++, 3, 1);

    GtkWidget *doc = zg_wrapped_label_new(info->doc);
    gtk_widget_set_margin_top(doc, 6);
    gtk_grid_attach(GTK_GRID(grid), doc, 0, row++, 3, 1);

    zg_grid_add_heading(grid, &row, "In your project");
    b->effect = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_grid_attach(GTK_GRID(grid), b->effect, 0, row++, 3, 1);
    fill_effect(b);
    gtk_box_append(GTK_BOX(b->detail), zg_scrolled_new(grid));

    b->focus = focus_of(info->name, &b->focus_first);
    send_focus(b);
}

/* ---- column 2 ---- */

static void on_row_value_changed(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *label = data;
    const zs_setting_info *info = g_object_get_data(G_OBJECT(label), "zg-info");
    if (strcmp(key, info->name) != 0) return;
    char *value = zg_model_get(model, key);
    char *text = zg_setting_value_with_unit(info, value);
    gtk_label_set_text(GTK_LABEL(label), text);
    g_free(text);
    g_free(value);
}

static GtkWidget *setting_row(Browser *b, const zs_setting_info *src, gboolean with_section) {
    zs_setting_info *info = g_new(zs_setting_info, 1);
    *info = *src;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(box, 10);
    gtk_widget_set_margin_end(box, 10);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);
    GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(names, TRUE);
    GtkWidget *name = gtk_label_new(info->label);
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(names), name);
    if (with_section) {
        char *where = g_strdup_printf("%s › %s", group_title(info->group), info->section);
        GtkWidget *w = gtk_label_new(where);
        g_free(where);
        gtk_label_set_xalign(GTK_LABEL(w), 0);
        gtk_label_set_ellipsize(GTK_LABEL(w), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(w, "dim-label");
        gtk_widget_add_css_class(w, "caption");
        gtk_box_append(GTK_BOX(names), w);
    }
    char *value = zg_model_get(b->model, info->name);
    char *text = zg_setting_value_with_unit(info, value);
    GtkWidget *v = gtk_label_new(text);
    g_free(text);
    g_free(value);
    gtk_label_set_ellipsize(GTK_LABEL(v), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(v), 12);
    gtk_widget_add_css_class(v, "dim-label");
    gtk_widget_add_css_class(v, "numeric");
    g_object_set_data_full(G_OBJECT(v), "zg-info", info, free_info);
    g_signal_connect_object(b->model, "setting-changed", G_CALLBACK(on_row_value_changed), v, 0);
    gtk_box_append(GTK_BOX(box), names);
    gtk_box_append(GTK_BOX(box), v);
    gtk_widget_set_tooltip_text(box, info->doc);
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "zg-key", (gpointer)info->name);
    return row;
}

static gboolean matches(const zs_setting_info *info, const char *needle) {
    char *hay = g_utf8_strdown(info->label, -1);
    gboolean hit = strstr(hay, needle) != NULL;
    g_free(hay);
    if (hit) return TRUE;
    hay = g_utf8_strdown(info->doc, -1);
    hit = strstr(hay, needle) != NULL;
    g_free(hay);
    return hit || strstr(info->name, needle) != NULL;
}

/* Fills column 2: the settings of a section, or the matches of a search. */
static void fill_settings(Browser *b, const char *group, const char *section, const char *search) {
    gtk_list_box_remove_all(GTK_LIST_BOX(b->settings));
    char *needle = search && search[0] ? g_utf8_strdown(search, -1) : NULL;
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK) continue;
        if (needle ? !matches(&info, needle) : (g_strcmp0(info.group, group) != 0 || g_strcmp0(info.section, section) != 0)) continue;
        GtkWidget *row = setting_row(b, &info, needle != NULL);
        gtk_list_box_append(GTK_LIST_BOX(b->settings), row);
        if (b->key && strcmp(b->key, info.name) == 0) gtk_list_box_select_row(GTK_LIST_BOX(b->settings), GTK_LIST_BOX_ROW(row));
    }
    g_free(needle);
}

/* Column 2 lists the settings that change the lines of feature f (or the
 * marks after the features): not the settings that change all lines (for
 * example the layer height), because they are in each list. */
static void show_feature(Browser *b, int f) {
    b->feature = f;
    b->section = NULL;
    gtk_list_box_unselect_all(GTK_LIST_BOX(b->sections));
    gtk_list_box_remove_all(GTK_LIST_BOX(b->settings));
    guint32 all = (1u << ZS_FEATURE_COUNT) - 1;
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK) continue;
        zs_setting_effect e = {0};
        zs_setting_get_effect(info.name, &e);
        if (!((e.features >> f) & 1) || (e.features & all) == all) continue;
        GtkWidget *row = setting_row(b, &info, TRUE);
        gtk_list_box_append(GTK_LIST_BOX(b->settings), row);
        if (b->key && strcmp(b->key, info.name) == 0) gtk_list_box_select_row(GTK_LIST_BOX(b->settings), GTK_LIST_BOX_ROW(row));
    }
    b->focus = 1u << f;
    b->focus_first = FALSE;
    send_focus(b);
    show_column(b, 1);
    update_crumbs(b);
}

static void on_feature_clicked(GtkButton *button, gpointer data) {
    show_feature(data, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "zg-feature")));
}

static void on_setting_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Browser *b = data;
    if (!row) return;
    const char *key = g_object_get_data(G_OBJECT(row), "zg-key");
    if (b->key && key && strcmp(b->key, key) == 0) return;
    show_detail(b, key);
    scroll_to_end(b);
}

/* ---- column 1 ---- */

static void on_section_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Browser *b = data;
    if (!row) return;
    /* A section ends a search. */
    if (gtk_editable_get_text(GTK_EDITABLE(b->search))[0]) {
        g_object_set_data(G_OBJECT(b->search), "zg-quiet", GINT_TO_POINTER(1));
        gtk_editable_set_text(GTK_EDITABLE(b->search), "");
        g_object_set_data(G_OBJECT(b->search), "zg-quiet", NULL);
    }
    const char *group = g_object_get_data(G_OBJECT(row), "zg-group");
    const char *section = g_object_get_data(G_OBJECT(row), "zg-section");
    b->feature = -1;
    b->group = group;
    b->section = section;
    fill_settings(b, group, section, NULL);
    /* A new section: its settings come to the front. */
    if (b->crumbs && b->column < 1) show_column(b, 1);
    else update_crumbs(b);
    /* A new section: its lines show, until a setting of it is picked. */
    zs_setting_info info;
    if (!b->key || !zg_setting_find(b->key, &info) || g_strcmp0(info.group, group) != 0 || g_strcmp0(info.section, section) != 0) {
        b->focus = section_focus(group, section);
        b->focus_first = FALSE;
        send_focus(b);
    }
}

static void on_search(GtkSearchEntry *entry, gpointer data) {
    Browser *b = data;
    if (g_object_get_data(G_OBJECT(entry), "zg-quiet")) return;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    b->feature = -1;
    if (text[0]) {
        gtk_list_box_unselect_all(GTK_LIST_BOX(b->sections));
        b->section = NULL;
        fill_settings(b, NULL, NULL, text);
        show_column(b, 1);
    } else {
        GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), 0);
        if (first) gtk_list_box_select_row(GTK_LIST_BOX(b->sections), first);
    }
}

static void section_header(GtkListBoxRow *row, GtkListBoxRow *before, gpointer data) {
    const char *group = g_object_get_data(G_OBJECT(row), "zg-group");
    const char *prev = before ? g_object_get_data(G_OBJECT(before), "zg-group") : NULL;
    if (prev && strcmp(prev, group) == 0) {
        gtk_list_box_row_set_header(row, NULL);
        return;
    }
    GtkWidget *h = gtk_label_new(group_title(group));
    gtk_widget_add_css_class(h, "heading");
    gtk_label_set_xalign(GTK_LABEL(h), 0);
    gtk_widget_set_margin_start(h, 10);
    gtk_widget_set_margin_top(h, before ? 14 : 6);
    gtk_widget_set_margin_bottom(h, 4);
    gtk_list_box_row_set_header(row, h);
}

static void add_sections(Browser *b) {
    size_t n = zs_setting_count();
    const char *last_group = NULL, *last_section = NULL;
    for (size_t g = 0; g < G_N_ELEMENTS(groups); g++) {
        for (size_t i = 0; i < n; i++) {
            zs_setting_info info;
            if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, groups[g].group) != 0) continue;
            if (last_group && strcmp(last_group, info.group) == 0 && g_strcmp0(last_section, info.section) == 0) continue;
            last_group = info.group;
            last_section = info.section;
            GtkWidget *label = gtk_label_new(info.section[0] ? info.section : "General");
            gtk_label_set_xalign(GTK_LABEL(label), 0);
            gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
            gtk_widget_set_margin_start(label, 18);
            gtk_widget_set_margin_end(label, 10);
            gtk_widget_set_margin_top(label, 5);
            gtk_widget_set_margin_bottom(label, 5);
            GtkWidget *row = gtk_list_box_row_new();
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), label);
            g_object_set_data(G_OBJECT(row), "zg-group", (gpointer)info.group);
            g_object_set_data(G_OBJECT(row), "zg-section", (gpointer)info.section);
            gtk_list_box_append(GTK_LIST_BOX(b->sections), row);
        }
    }
}

/* Right moves to the next column, Left to the column before it. */
static gboolean on_column_key(GtkEventControllerKey *ctrl, guint key, guint code, GdkModifierType mods, gpointer data) {
    Browser *b = data;
    GtkWidget *list = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    if (key == GDK_KEY_Right && list == b->sections) {
        GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(b->settings));
        if (!row) row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->settings), 0);
        if (row) {
            gtk_list_box_select_row(GTK_LIST_BOX(b->settings), row);
            gtk_widget_grab_focus(GTK_WIDGET(row));
        }
        return TRUE;
    }
    if (key == GDK_KEY_Left && list == b->settings) {
        GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(b->sections));
        if (row) gtk_widget_grab_focus(GTK_WIDGET(row));
        return TRUE;
    }
    return FALSE;
}

static GtkWidget *column(GtkWidget *child, int width) {
    GtkWidget *scroll = zg_scrolled_new(child);
    gtk_widget_set_size_request(scroll, width, -1);
    gtk_widget_set_hexpand(scroll, FALSE);
    return scroll;
}

/* The focus of the previews is only for the Settings page. */
static void on_page_changed(GObject *stack, GParamSpec *pspec, gpointer data) {
    Browser *b = data;
    send_focus(b);
}

/* A new slice: new times for the lines in column 3. */
static void on_browser_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    Browser *b = data;
    if (event == ZS_EVENT_SLICED) fill_effect(b);
}

static void browser_free(gpointer data) {
    Browser *b = data;
    g_signal_handlers_disconnect_by_data(b->model, b);
    if (b->scroll_tick) gtk_widget_remove_tick_callback(b->hscroll, b->scroll_tick);
    g_free(b);
}

/* Selects a setting: its section in column 1, and the setting in column 2. */
static void select_setting(Browser *b, const char *key) {
    zs_setting_info info;
    if (!zg_setting_find(key, &info)) return;
    for (int i = 0;; i++) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), i);
        if (!row) return;
        if (g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-group"), info.group) == 0 &&
            g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-section"), info.section) == 0) {
            gtk_list_box_select_row(GTK_LIST_BOX(b->sections), row);
            break;
        }
    }
    for (int i = 0;; i++) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->settings), i);
        if (!row) return;
        if (g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-key"), key) == 0) {
            gtk_list_box_select_row(GTK_LIST_BOX(b->settings), row);
            return;
        }
    }
}

GtkWidget *zg_settings_browser_new(ZgModel *model, GtkWidget *panel_stack) {
    Browser *b = g_new0(Browser, 1);
    b->model = model;
    b->feature = -1;
    b->stack = panel_stack;

    b->search = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(b->search), "Search settings");
    gtk_widget_set_tooltip_text(b->search, "The defaults for all prints. Changes for one part are in the Selected page.");
    gtk_widget_set_margin_start(b->search, 8);
    gtk_widget_set_margin_end(b->search, 8);
    gtk_widget_set_margin_top(b->search, 4);
    gtk_widget_set_margin_bottom(b->search, 4);
    g_signal_connect(b->search, "search-changed", G_CALLBACK(on_search), b);

    b->sections = gtk_list_box_new();
    gtk_widget_add_css_class(b->sections, "navigation-sidebar");
    gtk_list_box_set_header_func(GTK_LIST_BOX(b->sections), section_header, NULL, NULL);
    add_sections(b);
    b->settings = gtk_list_box_new();
    gtk_widget_add_css_class(b->settings, "navigation-sidebar");
    b->detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(b->detail, TRUE);

    for (int i = 0; i < 2; i++) {
        GtkEventController *keys = gtk_event_controller_key_new();
        g_signal_connect(keys, "key-pressed", G_CALLBACK(on_column_key), b);
        gtk_widget_add_controller(i == 0 ? b->sections : b->settings, keys);
    }
    g_signal_connect(b->sections, "row-selected", G_CALLBACK(on_section_selected), b);
    g_signal_connect(b->settings, "row-selected", G_CALLBACK(on_setting_selected), b);

    GtkWidget *col1 = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(col1), b->search);
    gtk_box_append(GTK_BOX(col1), column(b->sections, COL1_WIDTH));
    GtkWidget *cols = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(cols), col1);
    gtk_box_append(GTK_BOX(cols), gtk_separator_new(GTK_ORIENTATION_VERTICAL));
    gtk_box_append(GTK_BOX(cols), column(b->settings, COL2_WIDTH));
    gtk_box_append(GTK_BOX(cols), gtk_separator_new(GTK_ORIENTATION_VERTICAL));
    GtkWidget *col3 = b->detail;
    gtk_widget_set_size_request(col3, COL3_WIDTH, -1);
    gtk_widget_set_hexpand(col3, TRUE);
    gtk_box_append(GTK_BOX(cols), col3);

    b->hscroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(b->hscroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(b->hscroll), cols);
    gtk_widget_set_vexpand(b->hscroll, TRUE);

    /* The navigation bar: Back, and the path. In a narrow panel only one
     * or two columns show; the bar says where you are and goes back. */
    b->back = gtk_button_new_from_icon_name("go-previous-symbolic");
    gtk_widget_add_css_class(b->back, "flat");
    gtk_widget_set_tooltip_text(b->back, "Back to the column before");
    g_signal_connect(b->back, "clicked", G_CALLBACK(on_back), b);
    b->crumbs = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_widget_set_hexpand(b->crumbs, TRUE);
    GtkWidget *crumb_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(crumb_scroll), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(crumb_scroll), b->crumbs);
    gtk_widget_set_hexpand(crumb_scroll, TRUE);
    GtkWidget *nav = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(nav, "zg-nav");
    gtk_box_append(GTK_BOX(nav), b->back);
    gtk_box_append(GTK_BOX(nav), crumb_scroll);
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(page), nav);
    gtk_box_append(GTK_BOX(page), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(page), b->hscroll);
    b->page = page;
    g_object_set_data_full(G_OBJECT(page), "zg-browser", b, browser_free);

    show_detail(b, NULL);
    GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), 0);
    if (first) gtk_list_box_select_row(GTK_LIST_BOX(b->sections), first);
    g_signal_connect(panel_stack, "notify::visible-child", G_CALLBACK(on_page_changed), b);
    g_signal_connect(model, "core-event", G_CALLBACK(on_browser_core_event), b);
    /* For development and screenshots: ZSLICE_SETTING=project.layer_height
     * opens the browser at that setting. */
    const char *start = g_getenv("ZSLICE_SETTING");
    if (start) {
        select_setting(b, start);
        scroll_to_end(b);
        g_object_set_data(G_OBJECT(b->page), "zg-open", GINT_TO_POINTER(1));
    }
    update_crumbs(b);
    return b->page;
}

void zg_settings_browser_show_setting(GtkWidget *browser, const char *key) {
    Browser *b = g_object_get_data(G_OBJECT(browser), "zg-browser");
    if (!b) return;
    select_setting(b, key);
    scroll_to_end(b);
}

gboolean zg_settings_browser_opens_first(GtkWidget *browser) {
    return g_object_get_data(G_OBJECT(browser), "zg-open") != NULL;
}
