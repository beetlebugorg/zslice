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
#include <stdlib.h>
#include <string.h>

/* The groups of settings, in the order of the browser, with their titles. */
static const struct {
    const char *group;
    const char *title;
} groups[] = {
    {"profiles", "Layer profiles"},
    {"project", "Part"},
    {"filament", "Filament"},
    {"machine", "Printer"},
    {"engine", "Engine"},
};

typedef struct {
    ZgModel *model;
    GtkWidget *page;     /* the Settings page of the panel stack */
    GtkWidget *columns;  /* a stack: one column at a time */
    GtkWidget *search;
    GtkWidget *sections; /* column 1 */
    GtkWidget *settings; /* column 2 */
    GtkWidget *detail;   /* column 3: a box; its child is rebuilt */
    GtkWidget *effect;   /* in column 3: the lines of the project */
    const char *key;     /* the selected setting, or NULL */
    GtkWidget *stack;    /* the page stack of the panel */
    guint32 focus;       /* the focus of the previews for the selection */
    gboolean focus_first;
    /* The navigation bar: the column in front (0 sections, 1 settings,
     * 2 the setting), a Back button, and the path. */
    int column;
    GtkWidget *back;
    GtkWidget *crumbs;
    const char *group;   /* the selected section */
    const char *section;
    int feature;         /* the feature whose settings column 2 lists, or -1 */
    /* A layer profile in edit: the edits go to its layer range. */
    gboolean in_profile;
    double p_min, p_max;
    gboolean profile_list; /* column 2 lists the changes of the profile */
    GtkWidget *pbar, *pbar_title, *pbar_note, *rename_entry;
    /* The history of the panel (settings-panel.c): a call after each move,
     * and the Back button. `restoring`: a move back, with no call. */
    void (*nav_fn)(gpointer);
    void (*back_fn)(gpointer);
    gpointer nav_data;
    gboolean restoring;
} Browser;

static void fill_profiles(Browser *b);
static void update_bar(Browser *b);


static const char *feature_titles[] = {"Outer wall", "Inner wall", "Skin", "Sparse infill",
                                       "Ironing", "Skirt or brim", "Support", "Support interface",
                                       "Slope smoothing", "Slope ironing",
                                       "Seams", "Travel moves", "Retractions"};
enum { N_MARKS = 3 };

static const char *group_title(const char *group) {
    for (size_t i = 0; i < G_N_ELEMENTS(groups); i++) {
        if (strcmp(groups[i].group, group) == 0) return groups[i].title;
    }
    return group;
}

static void update_crumbs(Browser *b);
static void on_feature_clicked(GtkButton *button, gpointer data);

/* The panel is too narrow for three columns side by side, so one column
 * fills it at a time: forward slides in from the right, back from the
 * left. */
static void show_column(Browser *b, int c) {
    static const char *names[] = {"sections", "settings", "setting"};
    c = CLAMP(c, 0, 2);
    gtk_stack_set_transition_type(GTK_STACK(b->columns), c >= b->column ? GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT : GTK_STACK_TRANSITION_TYPE_SLIDE_RIGHT);
    b->column = c;
    gtk_stack_set_visible_child_name(GTK_STACK(b->columns), names[c]);
    update_crumbs(b);
}

static void scroll_to_end(Browser *b) {
    show_column(b, 2);
}

static void on_back(GtkButton *button, gpointer data) {
    Browser *b = data;
    /* The history of the panel, else the column before. */
    if (b->back_fn) b->back_fn(b->nav_data);
    else show_column(b, b->column - 1);
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
    gtk_widget_set_sensitive(b->back, b->column > 0 || b->back_fn);
    if (b->nav_fn && !b->restoring) b->nav_fn(b->nav_data);
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
static gboolean range_has(Browser *b, const char *key);

static void show_default(GtkWidget *box) {
    const zs_setting_info *info = g_object_get_data(G_OBJECT(box), "zg-info");
    ZgModel *model = g_object_get_data(G_OBJECT(box), "zg-model");
    GtkWidget *label = g_object_get_data(G_OBJECT(box), "zg-label");
    GtkWidget *reset = g_object_get_data(G_OBJECT(box), "zg-reset");
    Browser *b = g_object_get_data(G_OBJECT(box), "zg-browser");
    if (b && b->in_profile) {
        /* In a profile: changed for these layers, or the value of all
         * layers. */
        gboolean changed = range_has(b, info->name);
        if (!info->per_layer) {
            gtk_label_set_text(GTK_LABEL(label), "This setting is for the whole print. It cannot change for some layers.");
        } else if (changed) {
            gtk_label_set_text(GTK_LABEL(label), "Changed in this profile.");
        } else {
            char *all = zg_model_get(model, info->name);
            char *v = zg_setting_value_with_unit(info, all);
            char *text = g_strdup_printf("The same as for all layers (%s).", v);
            gtk_label_set_text(GTK_LABEL(label), text);
            g_free(text);
            g_free(v);
            g_free(all);
        }
        gtk_button_set_label(GTK_BUTTON(reset), "Remove the change");
        gtk_widget_set_opacity(reset, changed ? 1 : 0);
        gtk_widget_set_sensitive(reset, changed);
        return;
    }
    gtk_button_set_label(GTK_BUTTON(reset), "Reset");
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
    Browser *b = g_object_get_data(G_OBJECT(box), "zg-browser");
    if (b && b->in_profile) {
        zg_model_clear_override(model, info->name);
        show_default(box);
        return;
    }
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
    zg_setting_row_free(zg_setting_row_add(grid, &row, b->model, info, b->in_profile ? ZG_ROW_SCOPED : 0));

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
    g_object_set_data(G_OBJECT(def), "zg-browser", b);
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
    Browser *b = g_object_get_data(G_OBJECT(label), "zg-browser");
    GtkWidget *name = g_object_get_data(G_OBJECT(label), "zg-name");
    if (name) {
        if (b->in_profile && range_has(b, key)) gtk_widget_add_css_class(name, "zg-overridden");
        else gtk_widget_remove_css_class(name, "zg-overridden");
    }
    char *value = zg_model_get_for(model, key, b->in_profile);
    char *text = zg_setting_value_with_unit(info, value);
    gtk_label_set_text(GTK_LABEL(label), text);
    g_free(text);
    g_free(value);
}

/* The mark at the end of a row that opens the next column. */
static GtkWidget *chevron(void) {
    GtkWidget *c = gtk_image_new_from_icon_name("go-next-symbolic");
    gtk_widget_add_css_class(c, "dim-label");
    return c;
}

static void on_setting_activated(GtkListBox *box, GtkListBoxRow *row, gpointer data);

/* The › of a row: the detail page of its setting. */
static void on_more_clicked(GtkButton *button, gpointer data) {
    Browser *b = data;
    GtkListBoxRow *row = g_object_get_data(G_OBJECT(button), "zg-row");
    gtk_list_box_select_row(GTK_LIST_BOX(b->settings), row);
    on_setting_activated(GTK_LIST_BOX(b->settings), row, b);
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
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
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
    char *value = zg_model_get_for(b->model, info->name, b->in_profile);
    char *text = zg_setting_value_with_unit(info, value);
    GtkWidget *v = gtk_label_new(text);
    g_object_set_data(G_OBJECT(v), "zg-browser", b);
    g_object_set_data(G_OBJECT(v), "zg-name", name);
    /* In a profile: a changed setting has the accent color, and a setting
     * for the whole print is dim (it cannot change for some layers). */
    if (b->in_profile && range_has(b, info->name)) gtk_widget_add_css_class(name, "zg-overridden");
    if (b->in_profile && !info->per_layer) gtk_widget_add_css_class(names, "dim-label");
    g_free(text);
    g_free(value);
    gtk_label_set_ellipsize(GTK_LABEL(v), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(v), 16);
    gtk_widget_add_css_class(v, "numeric");
    gtk_widget_add_css_class(v, "zg-browser-value");
    g_object_set_data_full(G_OBJECT(v), "zg-info", info, free_info);
    g_signal_connect_object(b->model, "setting-changed", G_CALLBACK(on_row_value_changed), v, 0);
    gtk_box_append(GTK_BOX(box), names);
    GtkWidget *row = gtk_list_box_row_new();
    /* A quick change: the editor in the row (a number with its unit, a
     * switch, a choice). A text (the start G-code) shows its value, and
     * opens in the detail page. */
    if (info->kind != ZS_SETTING_TEXT) {
        GtkWidget *editor = zg_setting_editor_new(b->model, info, b->in_profile);
        gtk_widget_add_css_class(editor, "zg-compact");
        gtk_widget_set_valign(editor, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(box), editor);
        if (info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER) {
            GtkWidget *unit = gtk_label_new(info->unit);
            gtk_widget_add_css_class(unit, "dim-label");
            gtk_label_set_xalign(GTK_LABEL(unit), 0);
            gtk_label_set_width_chars(GTK_LABEL(unit), 6);
            gtk_label_set_max_width_chars(GTK_LABEL(unit), 13);
            gtk_label_set_ellipsize(GTK_LABEL(unit), PANGO_ELLIPSIZE_END);
            zg_setting_editor_show_speed(editor, unit);
            gtk_box_append(GTK_BOX(box), unit);
        }
        /* The value label stays out of view: it follows the changes for
         * the mark of a changed setting in a profile. */
        g_object_set_data_full(G_OBJECT(row), "zg-value", g_object_ref_sink(v), g_object_unref);
    } else {
        gtk_box_append(GTK_BOX(box), v);
    }
    /* The detail page: what the setting does, and the lines and the time
     * it changes in the project. */
    GtkWidget *more = gtk_button_new_from_icon_name("go-next-symbolic");
    gtk_widget_add_css_class(more, "flat");
    gtk_widget_set_valign(more, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(more, "What it does, and the lines and the time it changes");
    g_object_set_data(G_OBJECT(more), "zg-row", row);
    g_signal_connect(more, "clicked", G_CALLBACK(on_more_clicked), b);
    gtk_box_append(GTK_BOX(box), more);
    gtk_widget_set_tooltip_text(names, info->doc);
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
}

/* A click or Enter on a setting opens it. The arrows only select. */
static void on_setting_activated(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Browser *b = data;
    on_setting_selected(box, row, b);
    show_column(b, 2);
}

/* ---- layer profiles ---- */

static gboolean same_range(double a0, double a1, double b0, double b1) {
    return fabs(a0 - b0) < 1e-6 && fabs(a1 - b1) < 1e-6;
}

/* TRUE if the profile in edit changes the setting. */
static gboolean range_has(Browser *b, const char *key) {
    zs_app *core = zg_model_core(b->model);
    size_t n = zs_app_override_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(core, i, &o) == ZS_OK && same_range(o.z_min, o.z_max, b->p_min, b->p_max) &&
            strlen(key) == o.name_len && strncmp(key, o.name, o.name_len) == 0)
            return TRUE;
    }
    return FALSE;
}

static size_t range_changes(Browser *b, double z_min, double z_max) {
    zs_app *core = zg_model_core(b->model);
    size_t n = zs_app_override_count(core), count = 0;
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(core, i, &o) == ZS_OK && same_range(o.z_min, o.z_max, z_min, z_max)) count++;
    }
    return count;
}

/* The layers of a range, as the user counts them (from 1). */
static char *range_layers(Browser *b, double z_min, double z_max) {
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(b->model), &tp) != ZS_OK || tp.layer_count == 0) {
        if (z_min < -1e5) return g_strdup_printf("up to z %.2f mm", z_max);
        if (z_max > 1e5) return g_strdup_printf("from z %.2f mm up", z_min);
        return g_strdup_printf("z %.2f to %.2f mm", z_min, z_max);
    }
    size_t first = tp.layer_count, last = 0;
    for (size_t i = 0; i < tp.layer_count; i++) {
        double z = tp.layer_z[i];
        if (z >= z_min - 1e-4 && z <= z_max + 1e-4) {
            if (first == tp.layer_count) first = i;
            last = i;
        }
    }
    if (first == tp.layer_count) return g_strdup("no layers of this part");
    if (first == last) return g_strdup_printf("layer %zu", first + 1);
    return g_strdup_printf("layers %zu to %zu", first + 1, last + 1);
}

/* The name of a range: its profile name, or its layers. */
static char *range_name(Browser *b, double z_min, double z_max) {
    zs_app *core = zg_model_core(b->model);
    size_t n = zs_app_profile_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_layer_profile p;
        if (zs_app_profile_get(core, i, &p) == ZS_OK && same_range(p.z_min, p.z_max, z_min, z_max)) return g_strndup(p.name, p.name_len);
    }
    char *layers = range_layers(b, z_min, z_max);
    layers[0] = g_ascii_toupper(layers[0]);
    return layers;
}

static void update_bar(Browser *b) {
    if (!b->pbar) return;
    gtk_revealer_set_reveal_child(GTK_REVEALER(b->pbar), b->in_profile);
    if (!b->in_profile) return;
    char *name = range_name(b, b->p_min, b->p_max);
    char *layers = range_layers(b, b->p_min, b->p_max);
    layers[0] = g_ascii_toupper(layers[0]);
    size_t n = range_changes(b, b->p_min, b->p_max);
    char *note = n == 0 ? g_strdup_printf("%s · no changes yet. A change here applies only to these layers.", layers)
                        : g_strdup_printf("%s · %zu change%s. A change here applies only to these layers.", layers, n, n == 1 ? "" : "s");
    gtk_label_set_text(GTK_LABEL(b->pbar_title), name);
    gtk_label_set_text(GTK_LABEL(b->pbar_note), note);
    g_free(note);
    g_free(layers);
    g_free(name);
}

/* Column 2: the changes of the profile in edit. */
static void fill_profile_changes(Browser *b) {
    gtk_list_box_remove_all(GTK_LIST_BOX(b->settings));
    zs_app *core = zg_model_core(b->model);
    size_t n = zs_app_override_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(core, i, &o) != ZS_OK || !same_range(o.z_min, o.z_max, b->p_min, b->p_max)) continue;
        char *key = g_strndup(o.name, o.name_len);
        zs_setting_info info;
        if (zg_setting_find(key, &info)) gtk_list_box_append(GTK_LIST_BOX(b->settings), setting_row(b, &info, TRUE));
        g_free(key);
    }
}

/* Edits go to the range of the profile now: the scope of the model. */
static void apply_profile_scope(Browser *b) {
    if (!b->in_profile) return;
    double show = b->p_min < -1e5 ? b->p_max : b->p_min;
    zg_model_set_scope(b->model, TRUE, b->p_min, b->p_max, show);
}

/* Shows all the values of the columns again (for a profile, or not). */
static void refresh_columns(Browser *b) {
    if (b->profile_list) fill_profile_changes(b);
    else if (b->feature >= 0) show_feature(b, b->feature);
    else if (gtk_editable_get_text(GTK_EDITABLE(b->search))[0]) fill_settings(b, NULL, NULL, gtk_editable_get_text(GTK_EDITABLE(b->search)));
    else if (b->section) fill_settings(b, b->group, b->section, NULL);
    if (b->key) show_detail(b, b->key);
}

static void enter_profile(Browser *b, double z_min, double z_max) {
    b->in_profile = TRUE;
    b->p_min = z_min;
    b->p_max = z_max;
    apply_profile_scope(b);
    update_bar(b);
    fill_profiles(b);
}

static void leave_profile(Browser *b) {
    if (!b->in_profile) return;
    b->in_profile = FALSE;
    b->profile_list = FALSE;
    /* The edits of the browser are for all prints again. */
    zg_model_set_scope(b->model, FALSE, 0, 0, 0);
    update_bar(b);
    fill_profiles(b);
    show_column(b, 0);
    refresh_columns(b);
}

static void on_profile_done(GtkButton *button, gpointer data) {
    leave_profile(data);
}

static void on_profile_delete(GtkButton *button, gpointer data) {
    Browser *b = data;
    double lo = b->p_min, hi = b->p_max;
    leave_profile(b);
    zg_model_profile_remove(b->model, lo, hi);
}

static void on_rename_activate(GtkEntry *entry, gpointer data) {
    Browser *b = data;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (b->in_profile && text[0]) zg_model_profile_set(b->model, b->p_min, b->p_max, text);
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(entry), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
}

static void on_rename_show(GtkPopover *pop, gpointer data) {
    Browser *b = data;
    char *name = range_name(b, b->p_min, b->p_max);
    gtk_editable_set_text(GTK_EDITABLE(b->rename_entry), name);
    g_free(name);
    gtk_widget_grab_focus(b->rename_entry);
}

/* The bar over the columns while a profile is in edit. */
static GtkWidget *make_bar(Browser *b) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(box, "zg-profile-bar");
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    b->pbar_title = gtk_label_new("");
    gtk_widget_add_css_class(b->pbar_title, "heading");
    gtk_label_set_xalign(GTK_LABEL(b->pbar_title), 0);
    gtk_label_set_ellipsize(GTK_LABEL(b->pbar_title), PANGO_ELLIPSIZE_END);
    b->pbar_note = zg_wrapped_label_new("");
    gtk_widget_add_css_class(b->pbar_note, "caption");
    gtk_box_append(GTK_BOX(text), b->pbar_title);
    gtk_box_append(GTK_BOX(text), b->pbar_note);
    GtkWidget *rename = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(rename), "document-edit-symbolic");
    gtk_widget_add_css_class(rename, "flat");
    gtk_widget_set_tooltip_text(rename, "Rename the profile");
    gtk_widget_set_valign(rename, GTK_ALIGN_CENTER);
    GtkWidget *pop = gtk_popover_new();
    b->rename_entry = gtk_entry_new();
    gtk_entry_set_activates_default(GTK_ENTRY(b->rename_entry), FALSE);
    gtk_widget_set_size_request(b->rename_entry, 200, -1);
    g_signal_connect(b->rename_entry, "activate", G_CALLBACK(on_rename_activate), b);
    gtk_popover_set_child(GTK_POPOVER(pop), b->rename_entry);
    g_signal_connect(pop, "show", G_CALLBACK(on_rename_show), b);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(rename), pop);
    GtkWidget *del = gtk_button_new_from_icon_name("user-trash-symbolic");
    gtk_widget_add_css_class(del, "flat");
    gtk_widget_set_tooltip_text(del, "Delete the profile and all its changes");
    gtk_widget_set_valign(del, GTK_ALIGN_CENTER);
    g_signal_connect(del, "clicked", G_CALLBACK(on_profile_delete), b);
    GtkWidget *done = gtk_button_new_with_label("Done");
    gtk_widget_add_css_class(done, "suggested-action");
    gtk_widget_set_tooltip_text(done, "Stop the edit of this profile. Changes then go to all prints again.");
    gtk_widget_set_valign(done, GTK_ALIGN_CENTER);
    g_signal_connect(done, "clicked", G_CALLBACK(on_profile_done), b);
    gtk_box_append(GTK_BOX(box), text);
    gtk_box_append(GTK_BOX(box), rename);
    gtk_box_append(GTK_BOX(box), del);
    gtk_box_append(GTK_BOX(box), done);
    b->pbar = gtk_revealer_new();
    gtk_revealer_set_transition_type(GTK_REVEALER(b->pbar), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN);
    gtk_revealer_set_child(GTK_REVEALER(b->pbar), box);
    return b->pbar;
}

/* The rows of the layer profiles, at the top of column 1: the named
 * profiles and the other layer ranges with changes (from the Selected
 * page), lowest first. */
typedef struct {
    double z_min, z_max;
} Range;

static gint range_cmp(gconstpointer a, gconstpointer b) {
    const Range *x = a, *y = b;
    if (x->z_min != y->z_min) return x->z_min < y->z_min ? -1 : 1;
    return x->z_max < y->z_max ? -1 : x->z_max > y->z_max;
}

static void add_range(GArray *list, double z_min, double z_max) {
    /* The whole part is not a layer range (the part page has it). */
    if (z_min < -1e5 && z_max > 1e5) return;
    for (guint i = 0; i < list->len; i++) {
        Range *r = &g_array_index(list, Range, i);
        if (same_range(r->z_min, r->z_max, z_min, z_max)) return;
    }
    Range r = {z_min, z_max};
    g_array_append_val(list, r);
}

static void fill_profiles(Browser *b) {
    /* The old rows. */
    for (;;) {
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), 0);
        if (!row || g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-group"), "profiles") != 0) break;
        gtk_list_box_remove(GTK_LIST_BOX(b->sections), GTK_WIDGET(row));
    }
    zs_app *core = zg_model_core(b->model);
    GArray *list = g_array_new(FALSE, FALSE, sizeof(Range));
    size_t n = zs_app_profile_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_layer_profile p;
        if (zs_app_profile_get(core, i, &p) == ZS_OK) add_range(list, p.z_min, p.z_max);
    }
    n = zs_app_override_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(core, i, &o) == ZS_OK) add_range(list, o.z_min, o.z_max);
    }
    g_array_sort(list, range_cmp);
    int at = 0;
    if (list->len == 0) {
        GtkWidget *hint = zg_wrapped_label_new("None yet. Right-click a line in the 3D view, then \u201cNew profile from here up\u201d, to change any settings for some layers.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_widget_add_css_class(hint, "caption");
        gtk_widget_set_margin_start(hint, 18);
        gtk_widget_set_margin_end(hint, 10);
        gtk_widget_set_margin_top(hint, 2);
        gtk_widget_set_margin_bottom(hint, 4);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), hint);
        gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(row), FALSE);
        gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), FALSE);
        g_object_set_data(G_OBJECT(row), "zg-group", (gpointer) "profiles");
        gtk_list_box_insert(GTK_LIST_BOX(b->sections), row, at++);
    }
    for (guint i = 0; i < list->len; i++) {
        Range r = g_array_index(list, Range, i);
        char *name = range_name(b, r.z_min, r.z_max);
        char *layers = range_layers(b, r.z_min, r.z_max);
        size_t c = range_changes(b, r.z_min, r.z_max);
        char *sub = g_strdup_printf("%s · %zu change%s", layers, c, c == 1 ? "" : "s");
        GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(texts, TRUE);
        GtkWidget *t = gtk_label_new(name);
        gtk_label_set_xalign(GTK_LABEL(t), 0);
        gtk_label_set_ellipsize(GTK_LABEL(t), PANGO_ELLIPSIZE_END);
        GtkWidget *s = gtk_label_new(sub);
        gtk_label_set_xalign(GTK_LABEL(s), 0);
        gtk_widget_add_css_class(s, "dim-label");
        gtk_widget_add_css_class(s, "caption");
        gtk_box_append(GTK_BOX(texts), t);
        gtk_box_append(GTK_BOX(texts), s);
        GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_start(line, 18);
        gtk_widget_set_margin_top(line, 4);
        gtk_widget_set_margin_bottom(line, 4);
        gtk_box_append(GTK_BOX(line), texts);
        GtkWidget *mark = chevron();
        gtk_widget_set_margin_end(mark, 10);
        gtk_box_append(GTK_BOX(line), mark);
        if (b->in_profile && same_range(r.z_min, r.z_max, b->p_min, b->p_max)) gtk_widget_add_css_class(t, "heading");
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), line);
        g_object_set_data(G_OBJECT(row), "zg-group", (gpointer) "profiles");
        Range *keep = g_new(Range, 1);
        *keep = r;
        g_object_set_data_full(G_OBJECT(row), "zg-range", keep, g_free);
        gtk_list_box_insert(GTK_LIST_BOX(b->sections), row, at++);
        g_free(sub);
        g_free(layers);
        g_free(name);
    }
    g_array_free(list, TRUE);
}

/* A click on a profile: edit it, and list its changes. */
static void open_range(Browser *b, double z_min, double z_max) {
    enter_profile(b, z_min, z_max);
    b->profile_list = TRUE;
    b->feature = -1;
    b->section = NULL;
    fill_profile_changes(b);
    if (gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->settings), 0)) show_column(b, 1);
    else show_column(b, 0);
}

static void on_open_profile(ZgModel *model, double z_min, double z_max, gpointer data) {
    Browser *b = data;
    if (b->stack) gtk_stack_set_visible_child(GTK_STACK(b->stack), b->page);
    open_range(b, z_min, z_max);
    refresh_columns(b);
}

static void on_profiles_changed(ZgModel *model, gpointer data) {
    Browser *b = data;
    fill_profiles(b);
    update_bar(b);
}

/* ---- column 1 ---- */

static void on_section_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Browser *b = data;
    if (!row || g_object_get_data(G_OBJECT(row), "zg-range")) return;
    b->profile_list = FALSE;
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
    update_crumbs(b);
    /* A new section: its lines show, until a setting of it is picked. */
    zs_setting_info info;
    if (!b->key || !zg_setting_find(b->key, &info) || g_strcmp0(info.group, group) != 0 || g_strcmp0(info.section, section) != 0) {
        b->focus = section_focus(group, section);
        b->focus_first = FALSE;
        send_focus(b);
    }
}

/* A click or Enter on a section opens its settings. */
static void on_section_activated(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Browser *b = data;
    Range *r = g_object_get_data(G_OBJECT(row), "zg-range");
    if (r) {
        open_range(b, r->z_min, r->z_max);
        if (b->column == 1) {
            GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->settings), 0);
            if (first) gtk_widget_grab_focus(GTK_WIDGET(first));
        }
        return;
    }
    on_section_selected(box, row, b);
    show_column(b, 1);
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
            gtk_widget_set_margin_top(label, 5);
            gtk_widget_set_margin_bottom(label, 5);
            gtk_widget_set_hexpand(label, TRUE);
            GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
            gtk_box_append(GTK_BOX(line), label);
            GtkWidget *mark = chevron();
            gtk_widget_set_margin_end(mark, 10);
            gtk_box_append(GTK_BOX(line), mark);
            GtkWidget *row = gtk_list_box_row_new();
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), line);
            g_object_set_data(G_OBJECT(row), "zg-group", (gpointer)info.group);
            g_object_set_data(G_OBJECT(row), "zg-section", (gpointer)info.section);
            gtk_list_box_append(GTK_LIST_BOX(b->sections), row);
        }
    }
}

/* Right opens the selected row (as Enter does), Left goes back. */
static gboolean on_column_key(GtkEventControllerKey *ctrl, guint key, guint code, GdkModifierType mods, gpointer data) {
    Browser *b = data;
    GtkWidget *list = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    if (key == GDK_KEY_Right) {
        GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(list));
        if (!row) return FALSE;
        if (list == b->sections) {
            on_section_activated(GTK_LIST_BOX(list), row, b);
            GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->settings), 0);
            if (first) gtk_widget_grab_focus(GTK_WIDGET(first));
        } else {
            on_setting_activated(GTK_LIST_BOX(list), row, b);
        }
        return TRUE;
    }
    if (key == GDK_KEY_Left && list == b->settings) {
        show_column(b, 0);
        GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(b->sections));
        if (row) gtk_widget_grab_focus(GTK_WIDGET(row));
        return TRUE;
    }
    return FALSE;
}

/* The focus of the previews is only for the Settings page. */
static void on_page_changed(GObject *stack, GParamSpec *pspec, gpointer data) {
    Browser *b = data;
    send_focus(b);
    /* The Selected page sets its own scope; a profile in edit takes it
     * back when this page shows. */
    if (gtk_stack_get_visible_child(GTK_STACK(b->stack)) == b->page) apply_profile_scope(b);
}

/* A new slice: new times for the lines in column 3. */
static void on_browser_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    Browser *b = data;
    if (event == ZS_EVENT_SLICED) fill_effect(b);
}

static void browser_free(gpointer data) {
    Browser *b = data;
    g_signal_handlers_disconnect_by_data(b->model, b);
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
    g_signal_connect(b->sections, "row-activated", G_CALLBACK(on_section_activated), b);
    g_signal_connect(b->settings, "row-activated", G_CALLBACK(on_setting_activated), b);

    GtkWidget *col1 = zg_scrolled_new(b->sections);
    b->columns = gtk_stack_new();
    gtk_stack_set_transition_duration(GTK_STACK(b->columns), 160);
    gtk_stack_set_hhomogeneous(GTK_STACK(b->columns), TRUE);
    gtk_stack_add_named(GTK_STACK(b->columns), col1, "sections");
    gtk_stack_add_named(GTK_STACK(b->columns), zg_scrolled_new(b->settings), "settings");
    gtk_stack_add_named(GTK_STACK(b->columns), b->detail, "setting");
    gtk_widget_set_vexpand(b->columns, TRUE);
    gtk_widget_set_hexpand(b->columns, TRUE);

    /* The navigation bar: Back, and the path. It says where you are and
     * goes back. */
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
    gtk_box_append(GTK_BOX(page), make_bar(b));
    /* The search stays in view on all columns. */
    gtk_box_append(GTK_BOX(page), b->search);
    gtk_box_append(GTK_BOX(page), b->columns);
    b->page = page;
    g_object_set_data_full(G_OBJECT(page), "zg-browser", b, browser_free);

    show_detail(b, NULL);
    GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), 0);
    if (first) gtk_list_box_select_row(GTK_LIST_BOX(b->sections), first);
    g_signal_connect(panel_stack, "notify::visible-child", G_CALLBACK(on_page_changed), b);
    g_signal_connect(model, "core-event", G_CALLBACK(on_browser_core_event), b);
    g_signal_connect(model, "profiles-changed", G_CALLBACK(on_profiles_changed), b);
    g_signal_connect(model, "open-profile", G_CALLBACK(on_open_profile), b);
    fill_profiles(b);
    /* For development and screenshots: ZSLICE_SETTING=project.layer_height
     * opens the browser at that setting. */
    const char *start = g_getenv("ZSLICE_SETTING");
    if (start) {
        select_setting(b, start);
        /* ZSLICE_SETTING_LIST=1: the list of its section, not the detail. */
        if (g_getenv("ZSLICE_SETTING_LIST")) show_column(b, 1);
        else scroll_to_end(b);
        g_object_set_data(G_OBJECT(b->page), "zg-open", GINT_TO_POINTER(1));
    }
    update_crumbs(b);
    return b->page;
}

char *zg_settings_browser_get_place(GtkWidget *browser) {
    Browser *b = g_object_get_data(G_OBJECT(browser), "zg-browser");
    if (!b) return g_strdup("");
    return g_strdup_printf("%d\t%s\t%s\t%d\t%s", b->column, b->group ? b->group : "", b->section ? b->section : "\x1f",
                           b->feature, b->key ? b->key : "");
}

void zg_settings_browser_set_place(GtkWidget *browser, const char *place) {
    Browser *b = g_object_get_data(G_OBJECT(browser), "zg-browser");
    if (!b || !place) return;
    char **f = g_strsplit(place, "\t", 5);
    if (g_strv_length(f) == 5) {
        b->restoring = TRUE;
        int column = atoi(f[0]);
        int feature = atoi(f[3]);
        const char *section = strcmp(f[2], "\x1f") == 0 ? NULL : f[2];
        if (feature >= 0) {
            show_feature(b, feature);
        } else if (f[1][0] && section) {
            for (int i = 0;; i++) {
                GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(b->sections), i);
                if (!row) break;
                if (g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-group"), f[1]) == 0 &&
                    g_strcmp0(g_object_get_data(G_OBJECT(row), "zg-section"), section) == 0) {
                    gtk_list_box_select_row(GTK_LIST_BOX(b->sections), row);
                    break;
                }
            }
        }
        if (f[4][0]) {
            select_setting(b, f[4]);
            show_detail(b, f[4]);
        }
        show_column(b, column);
        b->restoring = FALSE;
    }
    g_strfreev(f);
}

void zg_settings_browser_set_history(GtkWidget *browser, void (*nav)(gpointer), void (*back)(gpointer), gpointer data) {
    Browser *b = g_object_get_data(G_OBJECT(browser), "zg-browser");
    if (!b) return;
    b->nav_fn = nav;
    b->back_fn = back;
    b->nav_data = data;
    update_crumbs(b);
}

void zg_settings_browser_up(GtkWidget *browser) {
    Browser *b = g_object_get_data(G_OBJECT(browser), "zg-browser");
    if (b && b->column > 0) show_column(b, b->column - 1);
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
