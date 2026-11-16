/* inspector.c: see inspector.h.
 *
 * After a new slice of the same line, the page changes the text in place
 * and keeps its rows: the page does not move, the editor with the focus
 * keeps it, and the tab stays. Another line gets new rows, with a short
 * crossfade between two slots of a stack.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "inspector.h"

#include "part-page.h"
#include "setting-editor.h"
#include "settings-browser.h"
#include "setting-row.h"
#include "widgets.h"

#include <string.h>

typedef struct {
    ZgModel *model;
    GtkWidget *stack;   /* the page stack of the panel */
    GtkWidget *slots;   /* two slots, "a" and "b", for a crossfade */
    gboolean in_a;      /* the visible slot is "a" */
    gboolean built;     /* the visible slot has content */
    char *signature;    /* the title and the setting names of the rows */
    /* The parts that change in place. */
    GtkWidget *title;
    GtkWidget *stat_value[3];
    GtkWidget *stat_note;  /* a revealer */
    GtkWidget *stat_note_label;
    /* The "why" text of each number (planned, real, flow), for the popover
     * of its button. */
    char *why[3];
    GtkWidget *explain;
    /* The scope of the edits: 0 all layers, 1 this layer, 2 this layer
     * and up, 3 this layer and down. It stays for the next selection. */
    int scope_mode;
    double scope_z;
    GtkWidget *scope_dd;
    /* The filter: the rows, and the section expanders. */
    GtkWidget *filter;
    GPtrArray *rows;
    GPtrArray *sections;
} Inspector;

/* Which sections of the inspector are open, by title. Kept for the next
 * selection. Speed and Shape start open. */
static GHashTable *section_open;

static gboolean section_is_open(const char *title) {
    gpointer v;
    if (section_open && g_hash_table_lookup_extended(section_open, title, NULL, &v)) return GPOINTER_TO_INT(v);
    return strcmp(title, "Material") != 0;
}

static void on_section_expanded(GObject *expander, GParamSpec *pspec, gpointer data) {
    Inspector *ins = data;
    /* An open for a filter is not a choice of the user. */
    if (ins->filter && gtk_editable_get_text(GTK_EDITABLE(ins->filter))[0]) return;
    if (!section_open) section_open = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_hash_table_insert(section_open, g_strdup(g_object_get_data(expander, "zg-title")),
                        GINT_TO_POINTER(gtk_expander_get_expanded(GTK_EXPANDER(expander))));
}

static void on_filter(GtkSearchEntry *entry, gpointer data) {
    Inspector *ins = data;
    char *needle = g_utf8_strdown(gtk_editable_get_text(GTK_EDITABLE(entry)), -1);
    for (guint i = 0; i < ins->rows->len; i++) {
        ZgSettingRow *r = g_ptr_array_index(ins->rows, i);
        gboolean show = !needle[0] || strstr(r->needle, needle);
        for (int k = 0; k < 4; k++) if (r->widgets[k]) gtk_widget_set_visible(r->widgets[k], show);
    }
    for (guint i = 0; i < ins->sections->len; i++) {
        GtkWidget *ex = g_ptr_array_index(ins->sections, i);
        if (needle[0]) {
            gtk_expander_set_expanded(GTK_EXPANDER(ex), TRUE);
        } else {
            gtk_expander_set_expanded(GTK_EXPANDER(ex), section_is_open(g_object_get_data(G_OBJECT(ex), "zg-title")));
        }
    }
    g_free(needle);
}

static const char *stat_names[3] = {"planned speed", "real speed", "flow"};

/* ---- why a number is what it is ---- */

/* The "why" text as Pango markup: each {{name}} becomes a link with the
 * label of the setting. */
static char *why_markup(const char *text) {
    GString *out = g_string_new(NULL);
    const char *p = text;
    while (*p) {
        const char *open = strstr(p, "{{");
        if (!open) {
            char *e = g_markup_escape_text(p, -1);
            g_string_append(out, e);
            g_free(e);
            break;
        }
        char *e = g_markup_escape_text(p, open - p);
        g_string_append(out, e);
        g_free(e);
        const char *close = strstr(open + 2, "}}");
        if (!close) break;
        char *name = g_strndup(open + 2, close - open - 2);
        zs_setting_info info;
        const char *label = zg_setting_find(name, &info) ? info.label : name;
        char *el = g_markup_escape_text(label, -1);
        g_string_append_printf(out, "<a href=\"setting:%s\">%s</a>", name, el);
        g_free(el);
        g_free(name);
        p = close + 2;
    }
    return g_string_free(out, FALSE);
}

/* A link in a "why" text: the field of that setting in the inspector, or
 * the setting in the Settings page. */
static gboolean on_why_link(GtkLabel *label, const char *uri, gpointer data) {
    Inspector *ins = data;
    if (!g_str_has_prefix(uri, "setting:")) return FALSE;
    const char *key = uri + 8;
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(label), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
    for (guint i = 0; ins->rows && i < ins->rows->len; i++) {
        ZgSettingRow *r = g_ptr_array_index(ins->rows, i);
        GtkWidget *editor = r->widgets[1];
        if (editor && g_strcmp0(zg_setting_editor_info(editor)->name, key) == 0 && gtk_widget_get_mapped(editor)) {
            gtk_widget_grab_focus(editor);
            return TRUE;
        }
    }
    GtkWidget *page = gtk_stack_get_child_by_name(GTK_STACK(ins->stack), "settings");
    if (page) {
        gtk_stack_set_visible_child_name(GTK_STACK(ins->stack), "settings");
        zg_settings_browser_show_setting(page, key);
    }
    return TRUE;
}

static gboolean why_unparent(gpointer data) {
    gtk_widget_unparent(data);
    g_object_unref(data);
    return G_SOURCE_REMOVE;
}

/* Removed after the close, not in its handler. */
static void on_why_closed(GtkPopover *pop, gpointer data) {
    g_idle_add(why_unparent, g_object_ref(pop));
}

static void on_stat_clicked(GtkButton *b, gpointer data) {
    Inspector *ins = data;
    int i = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-stat"));
    if (!ins->why[i] || !ins->why[i][0]) return;
    char *markup = why_markup(ins->why[i]);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    g_free(markup);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 46);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_margin_start(label, 6);
    gtk_widget_set_margin_end(label, 6);
    gtk_widget_set_margin_top(label, 4);
    gtk_widget_set_margin_bottom(label, 4);
    g_signal_connect(label, "activate-link", G_CALLBACK(on_why_link), ins);
    GtkWidget *pop = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(pop), label);
    gtk_widget_set_parent(pop, GTK_WIDGET(b));
    g_signal_connect(pop, "closed", G_CALLBACK(on_why_closed), NULL);
    gtk_popover_popup(GTK_POPOVER(pop));
}

/* The speed summary: three numbers with a caption under each. A click on
 * a number shows why it is what it is. */
static GtkWidget *make_stats(Inspector *ins) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_set_homogeneous(GTK_BOX(row), TRUE);
    for (int i = 0; i < 3; i++) {
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        ins->stat_value[i] = gtk_label_new("");
        gtk_widget_add_css_class(ins->stat_value[i], "zg-stat-value");
        GtkWidget *caption = gtk_label_new(stat_names[i]);
        gtk_widget_add_css_class(caption, "zg-stat-caption");
        gtk_label_set_ellipsize(GTK_LABEL(caption), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(box), ins->stat_value[i]);
        gtk_box_append(GTK_BOX(box), caption);
        /* A click: why the number is what it is, and how to change it. */
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "zg-stat");
        gtk_widget_add_css_class(button, "flat");
        gtk_button_set_child(GTK_BUTTON(button), box);
        gtk_widget_set_tooltip_text(button, "Why this value? Click for the numbers and the settings that change it.");
        g_object_set_data(G_OBJECT(button), "zg-stat", GINT_TO_POINTER(i));
        g_signal_connect(button, "clicked", G_CALLBACK(on_stat_clicked), ins);
        gtk_box_append(GTK_BOX(row), button);
    }
    return row;
}

static void show_stats(Inspector *ins, const zs_inspect *info) {
    char buf[64];
    g_snprintf(buf, sizeof buf, "%.0f mm/s", info->planned_speed);
    gtk_label_set_text(GTK_LABEL(ins->stat_value[0]), buf);
    g_snprintf(buf, sizeof buf, "%.0f mm/s", info->speed);
    gtk_label_set_text(GTK_LABEL(ins->stat_value[1]), buf);
    g_snprintf(buf, sizeof buf, "%.1f mm³/s", info->flow);
    gtk_label_set_text(GTK_LABEL(ins->stat_value[2]), buf);
    /* The reason of a lower real speed: cooling or acceleration. */
    gboolean slowed = info->slow_reason != 0;
    if (slowed) gtk_widget_add_css_class(ins->stat_value[1], "warning");
    else gtk_widget_remove_css_class(ins->stat_value[1], "warning");
    if (ins->stat_note_label) {
        gtk_label_set_text(GTK_LABEL(ins->stat_note_label),
                           info->slow_reason == 1 ? "This layer is short, so it prints slower to cool (filament minimum layer time). Click the real speed for more."
                                                  : "The segments are short: the head does not reach the full speed between the corners (acceleration). Click the real speed for more.");
    }
    gtk_revealer_set_reveal_child(GTK_REVEALER(ins->stat_note), slowed);
    const char *whys[3] = {info->why_planned, info->why_real, info->why_flow};
    for (int i = 0; i < 3; i++) {
        g_free(ins->why[i]);
        ins->why[i] = g_strdup(whys[i] ? whys[i] : "");
    }
}

/* Sends the scope to the model, for the z of the selection. */
static void apply_scope(Inspector *ins) {
    double z = ins->scope_z;
    /* Inline changes are always for the loaded part: an override of the
     * whole part, or of some layers. The defaults for all prints are in
     * the Settings page. */
    switch (ins->scope_mode) {
    case 1: zg_model_set_scope(ins->model, TRUE, z, z, z); break;
    case 2: zg_model_set_scope(ins->model, TRUE, z, 1e6, z); break;
    case 3: zg_model_set_scope(ins->model, TRUE, -1e6, z, z); break;
    default: zg_model_set_scope(ins->model, TRUE, -1e6, 1e6, z); break;
    }
}

static void on_scope_dd(GObject *dd, GParamSpec *pspec, gpointer data) {
    Inspector *ins = data;
    ins->scope_mode = (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    apply_scope(ins);
}

static void show_text(Inspector *ins, const zs_inspect *info) {
    ins->scope_z = info->z;
    apply_scope(ins);
    /* A multiple selection: the first line, and how many more. */
    guint n_more = 0;
    zg_model_more(ins->model, &n_more);
    char *title = n_more > 0 ? g_strdup_printf("%s · layer %zu, and %u more line%s", info->title, info->layer + 1, n_more, n_more == 1 ? "" : "s")
                             : g_strdup_printf("%s · layer %zu", info->title, info->layer + 1);
    gtk_label_set_text(GTK_LABEL(ins->title), title);
    g_free(title);
    gtk_label_set_text(GTK_LABEL(ins->explain), info->explain);
    show_stats(ins, info);
}

static gboolean focus_later(gpointer data) {
    gtk_widget_grab_focus(data);
    g_object_unref(data);
    return G_SOURCE_REMOVE;
}

/* Builds the rows for a selection. */
static GtkWidget *build_inspector(Inspector *ins, const zs_inspect *info) {
    GtkWidget *grid = zg_grid_new();
    int row = 0;
    if (!info) {
        zg_model_set_scope(ins->model, TRUE, -1e6, 1e6, 0);
        GtkWidget *hint = zg_wrapped_label_new("Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), hint, 0, row++, 3, 1);
        return grid;
    }
    ins->title = zg_grid_add_heading(grid, &row, "");
    gtk_widget_add_css_class(ins->title, "zg-insp-title");
    gtk_grid_attach(GTK_GRID(grid), make_stats(ins), 0, row++, 3, 1);
    GtkWidget *note = zg_wrapped_label_new("This layer is short, so it prints slower to cool (filament minimum layer time).");
    gtk_widget_add_css_class(note, "zg-note");
    ins->stat_note_label = note;
    ins->stat_note = gtk_revealer_new();
    gtk_revealer_set_child(GTK_REVEALER(ins->stat_note), note);
    gtk_grid_attach(GTK_GRID(grid), ins->stat_note, 0, row++, 3, 1);

    /* Change for: all layers, or the layers of the selection. */
    GtkWidget *scope_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(scope_row, 6);
    GtkWidget *scope_label = gtk_label_new("Change for");
    gtk_widget_add_css_class(scope_label, "dim-label");
    const char *scopes[] = {"This part (all layers)", "This layer", "This layer and up", "This layer and down", NULL};
    ins->scope_dd = gtk_drop_down_new_from_strings(scopes);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(ins->scope_dd), (guint)ins->scope_mode);
    gtk_widget_set_hexpand(ins->scope_dd, TRUE);
    gtk_widget_set_tooltip_text(ins->scope_dd, "Changes here are for this part only, and not for other prints: for all its layers, or only for the layers of the selected line. A changed setting shows in the accent color, with a button to remove the change. The defaults for all prints are in the Settings page.");
    g_signal_connect(ins->scope_dd, "notify::selected", G_CALLBACK(on_scope_dd), ins);
    gtk_box_append(GTK_BOX(scope_row), scope_label);
    gtk_box_append(GTK_BOX(scope_row), ins->scope_dd);
    gtk_grid_attach(GTK_GRID(grid), scope_row, 0, row++, 4, 1);
    GtkWidget *scope_note = zg_wrapped_label_new("Changes here are for this part. The defaults for all prints are in Settings.");
    gtk_widget_add_css_class(scope_note, "dim-label");
    gtk_widget_add_css_class(scope_note, "caption");
    gtk_grid_attach(GTK_GRID(grid), scope_note, 0, row++, 4, 1);

    ins->filter = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(ins->filter), "Filter settings");
    gtk_widget_set_margin_top(ins->filter, 6);
    g_signal_connect(ins->filter, "search-changed", G_CALLBACK(on_filter), ins);
    gtk_grid_attach(GTK_GRID(grid), ins->filter, 0, row++, 3, 1);
    if (ins->rows) g_ptr_array_free(ins->rows, TRUE);
    if (ins->sections) g_ptr_array_free(ins->sections, TRUE);
    ins->rows = g_ptr_array_new_with_free_func(zg_setting_row_free);
    ins->sections = g_ptr_array_new();

    /* Each section is an expander with its own grid. */
    GtkWidget *sec_grid = NULL;
    int sec_row = 0;
    char **names = g_strsplit(info->settings, "\n", -1);
    for (int i = 0; names[i]; i++) {
        if (g_str_has_prefix(names[i], "# ")) {
            const char *title = names[i] + 2;
            GtkWidget *ex = gtk_expander_new(NULL);
            GtkWidget *head = gtk_label_new(title);
            gtk_widget_add_css_class(head, "heading");
            gtk_expander_set_label_widget(GTK_EXPANDER(ex), head);
            g_object_set_data_full(G_OBJECT(ex), "zg-title", g_strdup(title), g_free);
            gtk_expander_set_expanded(GTK_EXPANDER(ex), section_is_open(title));
            g_signal_connect(ex, "notify::expanded", G_CALLBACK(on_section_expanded), ins);
            gtk_widget_set_margin_top(ex, 8);
            sec_grid = gtk_grid_new();
            gtk_grid_set_row_spacing(GTK_GRID(sec_grid), 3);
            gtk_grid_set_column_spacing(GTK_GRID(sec_grid), 6);
            gtk_widget_set_margin_top(sec_grid, 4);
            sec_row = 0;
            gtk_expander_set_child(GTK_EXPANDER(ex), sec_grid);
            gtk_grid_attach(GTK_GRID(grid), ex, 0, row++, 3, 1);
            g_ptr_array_add(ins->sections, ex);
            continue;
        }
        zs_setting_info s;
        if (!zg_setting_find(names[i], &s)) continue;
        if (!sec_grid) {
            sec_grid = grid;
            sec_row = row;
        }
        ZgSettingRow *r = zg_setting_row_add(sec_grid, &sec_row, ins->model, &s, ZG_ROW_COMPACT);
        g_ptr_array_add(ins->rows, r);
        /* For development and screenshots: ZSLICE_INSPECT_FOCUS=<setting>
         * focuses that row after the first selection. */
        static gboolean focused;
        const char *want = g_getenv("ZSLICE_INSPECT_FOCUS");
        if (!focused && want && strcmp(want, s.name) == 0) {
            focused = TRUE;
            g_timeout_add(600, focus_later, g_object_ref(r->widgets[1]));
        }
        if (sec_grid == grid) row = sec_row;
    }
    g_strfreev(names);

    GtkWidget *more = gtk_expander_new("How these values come about");
    gtk_widget_set_margin_top(more, 12);
    /* Not selectable: a selectable label can take the focus, and GTK then
     * selects all of its text. */
    ins->explain = zg_wrapped_label_new("");
    gtk_widget_add_css_class(ins->explain, "zg-explain");
    gtk_widget_set_margin_top(ins->explain, 6);
    gtk_expander_set_child(GTK_EXPANDER(more), ins->explain);
    gtk_grid_attach(GTK_GRID(grid), more, 0, row++, 3, 1);
    show_text(ins, info);
    return grid;
}

/* Shows the selection. The same line (same title and settings) after a new
 * slice: new text in the same rows. An other line: new rows, with a short
 * crossfade. */
static void fill_inspector(Inspector *ins) {
    gint64 path = zg_model_selected(ins->model);
    zs_inspect info;
    gboolean have = path >= 0 && zs_app_inspect(zg_model_core(ins->model), (size_t)path, &info) == ZS_OK;
    char *signature = have ? g_strconcat(info.title, "\n", info.settings, NULL) : g_strdup("");
    if (ins->built && g_strcmp0(signature, ins->signature) == 0) {
        g_free(signature);
        if (have) show_text(ins, &info);
        return;
    }
    g_free(ins->signature);
    ins->signature = signature;

    const char *next = ins->in_a ? "b" : "a";
    GtkWidget *old = gtk_stack_get_child_by_name(GTK_STACK(ins->slots), next);
    if (old) gtk_stack_remove(GTK_STACK(ins->slots), old);
    GtkWidget *content = build_inspector(ins, have ? &info : NULL);
    gtk_stack_add_named(GTK_STACK(ins->slots), zg_scrolled_new(content), next);
    gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
    ins->in_a = !ins->in_a;
    ins->built = TRUE;
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    Inspector *ins = data;
    /* The line is gone for this slice only (a value under a slider can
     * remove it): keep the page, dimmed, so the slider stays under the
     * pointer. */
    if (zg_model_selection_lost(model) && ins->built && ins->signature && ins->signature[0]) {
        gtk_widget_add_css_class(ins->slots, "zg-lost");
        return;
    }
    gtk_widget_remove_css_class(ins->slots, "zg-lost");
    fill_inspector(ins);
}

/* Ctrl+click on a part: the part page. */
static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    Inspector *ins = data;
    if (part < 0) {
        /* Back to the line, or the hint. */
        g_clear_pointer(&ins->signature, g_free);
        ins->built = FALSE;
        fill_inspector(ins);
        return;
    }
    const char *next = ins->in_a ? "b" : "a";
    GtkWidget *old = gtk_stack_get_child_by_name(GTK_STACK(ins->slots), next);
    if (old) gtk_stack_remove(GTK_STACK(ins->slots), old);
    gtk_stack_add_named(GTK_STACK(ins->slots), zg_scrolled_new(zg_part_page_new(ins->model)), next);
    gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
    ins->in_a = !ins->in_a;
    /* The next line selection builds the line page again. */
    g_clear_pointer(&ins->signature, g_free);
    ins->signature = g_strdup("part");
    gtk_stack_set_visible_child_name(GTK_STACK(ins->stack), "selected");
}

/* Only a click on a line opens the page. */
static void on_picked(ZgModel *model, gint64 path, gpointer data) {
    Inspector *ins = data;
    if (path >= 0) gtk_stack_set_visible_child_name(GTK_STACK(ins->stack), "selected");
}

/* While a slice runs, the numbers are old: dim them. */
static void on_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    Inspector *ins = data;
    gboolean slicing = zs_app_state(zg_model_core(model)) == ZS_STATE_SLICING;
    if (slicing) gtk_widget_add_css_class(ins->slots, "zg-stale");
    else gtk_widget_remove_css_class(ins->slots, "zg-stale");
}

static void inspector_free(gpointer data) {
    Inspector *ins = data;
    g_signal_handlers_disconnect_by_data(ins->model, ins);
    if (ins->rows) g_ptr_array_free(ins->rows, TRUE);
    if (ins->sections) g_ptr_array_free(ins->sections, TRUE);
    g_free(ins->signature);
    for (int i = 0; i < 3; i++) g_free(ins->why[i]);
    g_free(ins);
}

GtkWidget *zg_inspector_new(ZgModel *model, GtkWidget *panel_stack) {
    Inspector *ins = g_new0(Inspector, 1);
    ins->model = model;
    ins->stack = panel_stack;
    ins->slots = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(ins->slots), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(ins->slots), 140);
    gtk_widget_add_css_class(ins->slots, "zg-inspector");
    g_object_set_data_full(G_OBJECT(ins->slots), "zg-inspector", ins, inspector_free);
    fill_inspector(ins);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), ins);
    g_signal_connect(model, "picked", G_CALLBACK(on_picked), ins);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), ins);
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), ins);
    return ins->slots;
}
