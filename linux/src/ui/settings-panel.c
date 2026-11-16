/* settings-panel.c: see settings-panel.h.
 *
 * Each row has a label and an editor. The editor depends on the kind of the
 * setting:
 *   number, integer, one-line text: an entry, set on Enter or when the
 *     focus leaves it
 *   boolean: a switch
 *   choice: a drop-down
 *   multi-line text (G-code): a text view, set when the focus leaves it
 *
 * A value that the core rejects gets the "error" style, and the tooltip
 * says why. Each set starts a new slice (zg_model_set).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include <string.h>

static const struct {
    const char *group;
    const char *title;
} pages[] = {
    {"project", "Project"},
    {"filament", "Filament"},
    {"machine", "Machine"},
    {"engine", "Engine"},
};

static ZgModel *model_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-model");
}

static const char *key_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-key");
}

/* Sends a value to the core and shows an error if it is rejected. */
static void commit(GtkWidget *editor, const char *value) {
    GError *error = NULL;
    char *old = zg_model_get(model_of(editor), key_of(editor));
    gboolean same = g_strcmp0(old, value) == 0;
    g_free(old);
    if (same) {
        gtk_widget_remove_css_class(editor, "error");
        return;
    }
    if (zg_model_set(model_of(editor), key_of(editor), value, &error)) {
        gtk_widget_remove_css_class(editor, "error");
        gtk_widget_set_tooltip_text(editor, g_object_get_data(G_OBJECT(editor), "zg-doc"));
    } else {
        gtk_widget_add_css_class(editor, "error");
        gtk_widget_set_tooltip_text(editor, error->message);
        g_error_free(error);
    }
}

static void on_entry_commit(GtkWidget *entry) {
    commit(entry, gtk_editable_get_text(GTK_EDITABLE(entry)));
}

static void on_entry_activate(GtkEntry *entry, gpointer data) {
    on_entry_commit(GTK_WIDGET(entry));
}

static void on_focus_leave(GtkEventControllerFocus *ctrl, gpointer data) {
    GtkWidget *editor = data;
    if (GTK_IS_TEXT_VIEW(editor)) {
        GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor));
        GtkTextIter a, b;
        gtk_text_buffer_get_bounds(buf, &a, &b);
        char *text = gtk_text_buffer_get_text(buf, &a, &b, FALSE);
        commit(editor, text);
        g_free(text);
    } else {
        on_entry_commit(editor);
    }
}

static void on_switch(GObject *sw, GParamSpec *pspec, gpointer data) {
    commit(GTK_WIDGET(sw), gtk_switch_get_active(GTK_SWITCH(sw)) ? "true" : "false");
}

static void on_dropdown(GObject *dd, GParamSpec *pspec, gpointer data) {
    GtkStringObject *item = gtk_drop_down_get_selected_item(GTK_DROP_DOWN(dd));
    if (item) commit(GTK_WIDGET(dd), gtk_string_object_get_string(item));
}

static void tag(GtkWidget *editor, ZgModel *model, const zs_setting_info *info) {
    g_object_set_data(G_OBJECT(editor), "zg-model", model);
    g_object_set_data(G_OBJECT(editor), "zg-key", (gpointer)info->name);
    g_object_set_data(G_OBJECT(editor), "zg-doc", (gpointer)info->doc);
    gtk_widget_set_tooltip_text(editor, info->doc);
}

static void add_focus_commit(GtkWidget *editor) {
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(on_focus_leave), editor);
    gtk_widget_add_controller(editor, focus);
}

static GtkWidget *make_editor(ZgModel *model, const zs_setting_info *info) {
    char *value = zg_model_get(model, info->name);
    GtkWidget *editor = NULL;
    switch (info->kind) {
    case ZS_SETTING_BOOLEAN:
        editor = gtk_switch_new();
        gtk_switch_set_active(GTK_SWITCH(editor), strcmp(value, "true") == 0);
        gtk_widget_set_halign(editor, GTK_ALIGN_END);
        tag(editor, model, info);
        g_signal_connect(editor, "notify::active", G_CALLBACK(on_switch), NULL);
        break;
    case ZS_SETTING_CHOICE: {
        char **choices = g_strsplit(info->choices, "\n", -1);
        editor = gtk_drop_down_new_from_strings((const char *const *)choices);
        for (guint i = 0; choices[i]; i++) {
            if (strcmp(choices[i], value) == 0) gtk_drop_down_set_selected(GTK_DROP_DOWN(editor), i);
        }
        g_strfreev(choices);
        tag(editor, model, info);
        g_signal_connect(editor, "notify::selected", G_CALLBACK(on_dropdown), NULL);
        break;
    }
    case ZS_SETTING_TEXT:
        if (info->multiline) {
            editor = gtk_text_view_new();
            gtk_text_view_set_monospace(GTK_TEXT_VIEW(editor), TRUE);
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor)), value, -1);
            tag(editor, model, info);
            add_focus_commit(editor);
            break;
        }
        /* One-line text is an entry. */
        G_GNUC_FALLTHROUGH;
    default:
        editor = gtk_entry_new();
        gtk_editable_set_text(GTK_EDITABLE(editor), value);
        gtk_editable_set_width_chars(GTK_EDITABLE(editor), info->kind == ZS_SETTING_TEXT ? 14 : 8);
        if (info->kind != ZS_SETTING_TEXT) gtk_entry_set_input_purpose(GTK_ENTRY(editor), GTK_INPUT_PURPOSE_NUMBER);
        tag(editor, model, info);
        g_signal_connect(editor, "activate", G_CALLBACK(on_entry_activate), NULL);
        add_focus_commit(editor);
        break;
    }
    g_free(value);
    return editor;
}

static GtkWidget *new_grid(void) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_widget_set_margin_start(grid, 12);
    gtk_widget_set_margin_end(grid, 12);
    gtk_widget_set_margin_top(grid, 12);
    gtk_widget_set_margin_bottom(grid, 12);
    return grid;
}

/* Adds the label and the editor of one setting to a grid. */
static void add_row(GtkWidget *grid, int *row, ZgModel *model, const zs_setting_info *info, gboolean with_group) {
    char *text = with_group ? g_strdup_printf("%s (%s)", info->label, info->group) : g_strdup(info->label);
    GtkWidget *label = gtk_label_new(text);
    g_free(text);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_widget_set_tooltip_text(label, info->doc);
    GtkWidget *editor = make_editor(model, info);
    if (info->kind == ZS_SETTING_TEXT && info->multiline) {
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 120);
        gtk_widget_add_css_class(scroll, "frame");
        gtk_grid_attach(GTK_GRID(grid), label, 0, (*row)++, 2, 1);
        gtk_grid_attach(GTK_GRID(grid), scroll, 0, (*row)++, 2, 1);
    } else {
        gtk_grid_attach(GTK_GRID(grid), label, 0, *row, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), editor, 1, (*row)++, 1, 1);
    }
}

static void add_heading(GtkWidget *grid, int *row, const char *text) {
    GtkWidget *heading = gtk_label_new(text);
    gtk_widget_add_css_class(heading, "heading");
    gtk_widget_set_halign(heading, GTK_ALIGN_START);
    gtk_widget_set_margin_top(heading, *row == 0 ? 0 : 12);
    gtk_grid_attach(GTK_GRID(grid), heading, 0, (*row)++, 2, 1);
}

static GtkWidget *scrolled(GtkWidget *child) {
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), child);
    gtk_widget_set_vexpand(scroll, TRUE);
    return scroll;
}

static GtkWidget *make_page(ZgModel *model, const char *group) {
    GtkWidget *grid = new_grid();
    int row = 0;
    const char *section = NULL;
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, group) != 0) continue;
        if (info.section[0] && g_strcmp0(section, info.section) != 0) {
            section = info.section;
            add_heading(grid, &row, section);
        }
        add_row(grid, &row, model, &info, FALSE);
    }

    return scrolled(grid);
}

/* ---- the inspector page ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *stack;
    GtkWidget *page; /* a box; its child is rebuilt for each selection */
} Inspector;

static gboolean find_setting(const char *name, zs_setting_info *out) {
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        if (zs_setting_get_info(i, out) == ZS_OK && strcmp(out->name, name) == 0) return TRUE;
    }
    return FALSE;
}

static void fill_inspector(Inspector *ins) {
    GtkWidget *old = gtk_widget_get_first_child(ins->page);
    if (old) gtk_box_remove(GTK_BOX(ins->page), old);
    GtkWidget *grid = new_grid();
    int row = 0;
    gint64 path = zg_model_selected(ins->model);
    zs_inspect info;
    if (path < 0 || zs_app_inspect(zg_model_core(ins->model), (size_t)path, &info) != ZS_OK) {
        GtkWidget *hint = gtk_label_new("Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it.");
        gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
        gtk_label_set_xalign(GTK_LABEL(hint), 0);
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), hint, 0, row++, 2, 1);
    } else {
        add_heading(grid, &row, info.title);
        GtkWidget *explain = gtk_label_new(info.explain);
        gtk_label_set_wrap(GTK_LABEL(explain), TRUE);
        gtk_label_set_xalign(GTK_LABEL(explain), 0);
        gtk_label_set_selectable(GTK_LABEL(explain), TRUE);
        gtk_widget_set_hexpand(explain, TRUE);
        gtk_grid_attach(GTK_GRID(grid), explain, 0, row++, 2, 1);
        add_heading(grid, &row, "Settings that change it");
        char **names = g_strsplit(info.settings, "\n", -1);
        for (int i = 0; names[i]; i++) {
            zs_setting_info s;
            if (find_setting(names[i], &s)) add_row(grid, &row, ins->model, &s, TRUE);
        }
        g_strfreev(names);
    }
    gtk_box_append(GTK_BOX(ins->page), scrolled(grid));
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    Inspector *ins = data;
    fill_inspector(ins);
    if (path >= 0) gtk_stack_set_visible_child_name(GTK_STACK(ins->stack), "selected");
}

static void inspector_free(gpointer data) {
    Inspector *ins = data;
    g_signal_handlers_disconnect_by_data(ins->model, ins);
    g_free(ins);
}

GtkWidget *zg_settings_panel_new(ZgModel *model) {
    GtkWidget *stack = gtk_stack_new();
    Inspector *ins = g_new0(Inspector, 1);
    ins->model = model;
    ins->stack = stack;
    ins->page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    g_object_set_data_full(G_OBJECT(ins->page), "zg-inspector", ins, inspector_free);
    fill_inspector(ins);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), ins);
    gtk_stack_add_titled(GTK_STACK(stack), ins->page, "selected", "Selected");
    for (size_t i = 0; i < G_N_ELEMENTS(pages); i++) {
        gtk_stack_add_titled(GTK_STACK(stack), make_page(model, pages[i].group), pages[i].group, pages[i].title);
    }
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(switcher, 8);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(box), switcher);
    gtk_box_append(GTK_BOX(box), stack);
    gtk_widget_set_size_request(box, 340, -1);
    return box;
}
