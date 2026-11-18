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

#include <math.h>
#include <string.h>

typedef struct {
    ZgModel *model;
    GtkWidget *stack;   /* the page stack of the panel */
    GtkWidget *slots;   /* two slots, "a" and "b", for a crossfade */
    gboolean in_a;      /* the visible slot is "a" */
    /* The selected gap: its layer and its center, to find it again after
     * a new slice (its index can change). */
    gint64 gap_layer;
    double gap_x, gap_y;
    gboolean built;     /* the visible slot has content */
    char *signature;    /* the title and the setting names of the rows */
    /* The parts that change in place. */
    GtkWidget *title;
    GtkWidget *stat_value[3];
    GtkWidget *stat_note;  /* a revealer */
    GtkWidget *stat_note_label;
    /* The measurements of the selected segment and its path. */
    GtkWidget *measure;
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
    /* The Settings page can have a scope of its own (a layer profile in
     * edit): set the scope only while this page shows. */
    if (ins->stack && gtk_stack_get_visible_child(GTK_STACK(ins->stack)) != ins->slots) return;
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

/* The measurements of the selected segment: its length, the straight edge
 * it is a part of, the path, the size of a loop, and the radius of a circle
 * or an arc (zs_app_measure). */
static void show_measure(Inspector *ins) {
    if (!ins->measure) return;
    gint64 path = zg_model_selected(ins->model);
    gint64 seg = zg_model_segment(ins->model);
    zs_measure m;
    if (path < 0 || zs_app_measure(zg_model_core(ins->model), (size_t)path, seg < 0 ? 0 : (size_t)seg, &m) != ZS_OK) {
        gtk_widget_set_visible(ins->measure, FALSE);
        return;
    }
    GString *t = g_string_new(NULL);
    if (m.shape == 1)
        g_string_append_printf(t, "<b>Circle</b>  radius %.2f mm · diameter %.2f mm\n", m.radius, 2 * m.radius);
    else if (m.shape == 2)
        g_string_append_printf(t, "<b>Arc</b>  radius %.2f mm · %.0f°\n", m.radius, m.angle);
    g_string_append_printf(t, "<b>Segment</b>  %.2f mm", m.segment_length);
    if (m.edge_length > m.segment_length + 0.01) g_string_append_printf(t, " · <b>edge</b> %.2f mm", m.edge_length);
    g_string_append_printf(t, "\n<b>%s</b>  %.2f mm", m.closed ? "Loop" : "Path", m.path_length);
    g_string_append_printf(t, " · %.2f × %.2f mm", m.size_x, m.size_y);
    gtk_label_set_markup(GTK_LABEL(ins->measure), t->str);
    gtk_widget_set_visible(ins->measure, TRUE);
    g_string_free(t, TRUE);
}

static void on_segment_measure(ZgModel *model, gint64 segment, gpointer data) {
    show_measure(data);
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
    show_measure(ins);
}

static gboolean focus_later(gpointer data) {
    gtk_widget_grab_focus(data);
    g_object_unref(data);
    return G_SOURCE_REMOVE;
}

/* Builds the rows for a selection. */
/* ---- a support mark of the user at the selected line ---- */

/* The support mark at the selected line: under its point (a support line
 * under the mark), or at its layer; -1 if none. */
static gint64 mark_of_selection(Inspector *ins) {
    gint64 path = zg_model_selected(ins->model);
    zs_toolpaths tp;
    zs_app *core = zg_model_core(ins->model);
    if (path < 0 || zs_app_mark_count(core) == 0 || zs_app_toolpaths(core, &tp) != ZS_OK || (size_t)path >= tp.path_count) return -1;
    uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
    if (b <= a) return -1;
    gint64 seg = zg_model_segment(ins->model);
    uint32_t i = seg >= 0 && a + (uint32_t)seg < b ? a + (uint32_t)seg : a + (b - a) / 2;
    double x = tp.points[2 * i], y = tp.points[2 * i + 1];
    size_t layer = 0;
    while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
    double z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
    int f = tp.path_features[path];
    gboolean support = f == ZS_FEATURE_SUPPORT || f == ZS_FEATURE_SUPPORT_INTERFACE;
    /* A support line: a mark above it (the support goes down from the
     * mark: a z from the line up to 1 m above it). Another line: a mark on
     * its layer. */
    ptrdiff_t m = support ? zs_app_mark_at(core, x, y, z + 500, 500) : zs_app_mark_at(core, x, y, z, 0.05);
    if (m >= 0) return m;
    return -1;
}

static void on_mark_kind(GObject *dd, GParamSpec *ps, gpointer data) {
    Inspector *ins = data;
    gint64 m = GPOINTER_TO_INT(g_object_get_data(dd, "zg-mark")) - 1;
    double r = 3;
    zs_app_mark_get(zg_model_core(ins->model), (size_t)m, NULL, NULL, NULL, &r, NULL);
    zg_model_mark_set(ins->model, (size_t)m, (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)), r);
}

static void on_mark_radius(GtkSpinButton *spin, gpointer data) {
    Inspector *ins = data;
    gint64 m = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(spin), "zg-mark")) - 1;
    int kind = 0;
    zs_app_mark_get(zg_model_core(ins->model), (size_t)m, NULL, NULL, NULL, NULL, &kind);
    zg_model_mark_set(ins->model, (size_t)m, kind, gtk_spin_button_get_value(spin));
}

static void on_mark_remove(GtkButton *b, gpointer data) {
    Inspector *ins = data;
    gint64 m = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-mark")) - 1;
    zg_model_mark_remove(ins->model, (size_t)m);
}

/* "Support you added": the kind and the size of the mark, and Remove. */
static void add_mark_block(Inspector *ins, GtkWidget *grid, int *row) {
    gint64 m = mark_of_selection(ins);
    if (m < 0) return;
    double r = 3;
    int kind = 0;
    if (zs_app_mark_get(zg_model_core(ins->model), (size_t)m, NULL, NULL, NULL, &r, &kind) != ZS_OK) return;
    GtkWidget *head = zg_grid_add_heading(grid, row, "Support you added");
    gtk_widget_set_margin_top(head, 8);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    static const char *kinds[] = {"Grid", "Tree", "Bridge pad", "Block (no support)", NULL};
    GtkWidget *dd = gtk_drop_down_new_from_strings(kinds);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), (guint)kind);
    g_object_set_data(G_OBJECT(dd), "zg-mark", GINT_TO_POINTER((int)m + 1));
    g_signal_connect(dd, "notify::selected", G_CALLBACK(on_mark_kind), ins);
    GtkWidget *spin = gtk_spin_button_new_with_range(0.5, 30, 0.5);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), r);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(spin), 1);
    gtk_widget_set_tooltip_text(spin, "The radius of the area of the mark, mm");
    g_object_set_data(G_OBJECT(spin), "zg-mark", GINT_TO_POINTER((int)m + 1));
    g_signal_connect(spin, "value-changed", G_CALLBACK(on_mark_radius), ins);
    GtkWidget *unit = gtk_label_new("mm");
    gtk_widget_add_css_class(unit, "dim-label");
    GtkWidget *rm = gtk_button_new_with_label("Remove");
    gtk_widget_add_css_class(rm, "destructive-action");
    g_object_set_data(G_OBJECT(rm), "zg-mark", GINT_TO_POINTER((int)m + 1));
    g_signal_connect(rm, "clicked", G_CALLBACK(on_mark_remove), ins);
    gtk_box_append(GTK_BOX(box), dd);
    gtk_box_append(GTK_BOX(box), spin);
    gtk_box_append(GTK_BOX(box), unit);
    gtk_box_append(GTK_BOX(box), rm);
    gtk_grid_attach(GTK_GRID(grid), box, 0, (*row)++, 4, 1);
}

static GtkWidget *build_inspector(Inspector *ins, const zs_inspect *info) {
    GtkWidget *grid = zg_grid_new();
    /* The label of the page before goes with its slot. */
    ins->measure = NULL;
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
    ins->measure = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(ins->measure), 0);
    gtk_label_set_wrap(GTK_LABEL(ins->measure), TRUE);
    gtk_label_set_selectable(GTK_LABEL(ins->measure), FALSE);
    gtk_widget_add_css_class(ins->measure, "numeric");
    gtk_widget_set_margin_top(ins->measure, 4);
    gtk_widget_set_tooltip_text(ins->measure, "The measurements of the selected segment: its length, the straight edge that it is a part of, the whole line, and the radius of a circle or an arc.");
    gtk_grid_attach(GTK_GRID(grid), ins->measure, 0, row++, 3, 1);
    add_mark_block(ins, grid, &row);

    /* Change for: all layers, or the layers of the selection. */
    GtkWidget *scope_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(scope_row, 6);
    GtkWidget *scope_label = gtk_label_new("Change for");
    gtk_widget_add_css_class(scope_label, "dim-label");
    const char *scopes[] = {"This print (all layers)", "This layer", "This layer and up", "This layer and down", NULL};
    ins->scope_dd = gtk_drop_down_new_from_strings(scopes);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(ins->scope_dd), (guint)ins->scope_mode);
    gtk_widget_set_hexpand(ins->scope_dd, TRUE);
    gtk_widget_set_tooltip_text(ins->scope_dd, "Changes here are for this print: for all its layers, or only for the layers of the selected line. A changed setting shows in the accent color, with a button to remove the change. For one part of the plate: Settings, then Settings for: the part.");
    g_signal_connect(ins->scope_dd, "notify::selected", G_CALLBACK(on_scope_dd), ins);
    gtk_box_append(GTK_BOX(scope_row), scope_label);
    gtk_box_append(GTK_BOX(scope_row), ins->scope_dd);
    gtk_grid_attach(GTK_GRID(grid), scope_row, 0, row++, 4, 1);
    GtkWidget *scope_note = zg_wrapped_label_new("Changes here are for this print. Settings has the settings of one part, and your profiles.");
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
    ins->measure = NULL;
    gtk_stack_add_named(GTK_STACK(ins->slots), zg_scrolled_new(zg_part_page_new(ins->model)), next);
    gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
    ins->in_a = !ins->in_a;
    /* The next line selection builds the line page again. */
    g_clear_pointer(&ins->signature, g_free);
    ins->signature = g_strdup("part");
    gtk_stack_set_visible_child_name(GTK_STACK(ins->stack), "selected");
}

/* ---- the gap page ---- */

static const char *feature_names[] = {"outer wall", "inner wall", "skin", "sparse infill", "ironing", "skirt or brim",
                                      "support", "support interface", "slope smoothing", "slope ironing"};

typedef struct {
    ZgModel *model;
    char *name, *value;
    double z;     /* the top of the layer of the gap */
    gboolean layer_only;
} GapStep;

static void gap_step_free(gpointer data, GClosure *closure) {
    GapStep *st = data;
    g_free(st->name);
    g_free(st->value);
    g_free(st);
}

/* Apply a step: for all layers, or for the layer of the gap only (an
 * override of that layer). The slice runs again, and the gaps of the layer
 * show the result. */
static void on_gap_apply(GtkButton *b, gpointer data) {
    GapStep *st = data;
    GError *error = NULL;
    if (st->layer_only) {
        zg_model_set_scope(st->model, TRUE, st->z, st->z, st->z);
        zg_model_set_for(st->model, st->name, st->value, TRUE, &error);
    } else {
        zg_model_set(st->model, st->name, st->value, &error);
    }
    if (error) {
        g_warning("zslice: %s = %s: %s", st->name, st->value, error->message);
        g_error_free(error);
    }
}

static GtkWidget *build_gap_page(Inspector *ins, gint64 layer, gint64 index) {
    GtkWidget *grid = zg_grid_new();
    int row = 0;
    zs_app *core = zg_model_core(ins->model);
    const zs_gap *gaps = NULL;
    size_t n = 0;
    if (zs_app_layer_gaps(core, (size_t)layer, &gaps, &n, NULL, NULL) != ZS_OK || index >= (gint64)n) {
        zg_grid_add_heading(grid, &row, "The gap is gone: the layer has changed.");
        return grid;
    }
    const zs_gap *g = &gaps[index];
    ins->gap_layer = layer;
    ins->gap_x = g->x;
    ins->gap_y = g->y;
    char *title = g_strdup_printf("Gap · layer %lld", (long long)layer + 1);
    GtkWidget *t = zg_grid_add_heading(grid, &row, title);
    gtk_widget_add_css_class(t, "title-4");
    g_free(title);
    GString *next = g_string_new(NULL);
    for (size_t f = 0; f < G_N_ELEMENTS(feature_names); f++) {
        if (!(g->features & (1u << f))) continue;
        if (next->len) g_string_append(next, ", ");
        g_string_append(next, feature_names[f]);
    }
    char *facts = g_strdup_printf("%.3f mm², %.2f mm wide, at %.1f, %.1f mm. Next to: %s.%s", g->area, g->width, g->x, g->y,
                                  next->len ? next->str : "no bead",
                                  g->at_edge ? " It touches the edge of the solid area (the outline, or the sparse infill)." : "");
    g_string_free(next, TRUE);
    GtkWidget *f = zg_wrapped_label_new(facts);
    g_free(facts);
    gtk_grid_attach(GTK_GRID(grid), f, 0, row++, 3, 1);
    zs_toolpaths tp;
    double z = 0;
    if (zs_app_toolpaths(core, &tp) == ZS_OK && (size_t)layer < tp.layer_count) z = tp.layer_z[layer];

    zg_grid_add_heading(grid, &row, "Settings that can close it");
    zs_gap_step steps[8];
    size_t ns = 0;
    if (zs_app_gap_advice(core, (size_t)layer, (size_t)index, steps, G_N_ELEMENTS(steps), &ns) != ZS_OK) ns = 0;
    for (size_t i = 0; i < MIN(ns, G_N_ELEMENTS(steps)); i++) {
        char *name = g_strndup(steps[i].name, steps[i].name_len);
        char *value = g_strndup(steps[i].value, steps[i].value_len);
        char *why = g_strndup(steps[i].why, steps[i].why_len);
        zs_setting_info info;
        gboolean known = zg_setting_find(name, &info);
        char *now = zg_model_get_for(ins->model, name, FALSE);
        char *now_text = known ? zg_setting_value_with_unit(&info, now) : g_strdup(now);
        char *to_text = known ? zg_setting_value_with_unit(&info, value) : g_strdup(value);
        char *head = g_strdup_printf("%s: %s \u2192 %s", known ? info.label : name, now_text, to_text);
        GtkWidget *h = gtk_label_new(head);
        gtk_label_set_xalign(GTK_LABEL(h), 0);
        gtk_label_set_wrap(GTK_LABEL(h), TRUE);
        gtk_widget_add_css_class(h, "heading");
        gtk_widget_set_margin_top(h, 8);
        gtk_grid_attach(GTK_GRID(grid), h, 0, row++, 3, 1);
        GtkWidget *w = zg_wrapped_label_new(why);
        gtk_widget_add_css_class(w, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), w, 0, row++, 3, 1);
        GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        for (int k = 0; k < 2; k++) {
            if (k == 1 && !(known && info.per_layer)) break;
            GapStep *st = g_new0(GapStep, 1);
            st->model = ins->model;
            st->name = g_strdup(name);
            st->value = g_strdup(value);
            st->z = z;
            st->layer_only = k == 1;
            GtkWidget *b = gtk_button_new_with_label(k == 0 ? "Apply" : "This layer");
            gtk_widget_set_tooltip_text(b, k == 0 ? "Change the setting for all prints, and slice again." : "Change the setting only for this layer of this part, and slice again.");
            g_signal_connect_data(b, "clicked", G_CALLBACK(on_gap_apply), st, gap_step_free, 0);
            gtk_box_append(GTK_BOX(buttons), b);
        }
        gtk_grid_attach(GTK_GRID(grid), buttons, 0, row++, 3, 1);
        g_free(head);
        g_free(to_text);
        g_free(now_text);
        g_free(now);
        g_free(why);
        g_free(value);
        g_free(name);
    }
    return grid;
}

static void on_gaps_changed(ZgModel *model, gpointer data) {
    Inspector *ins = data;
    gint64 layer = -1;
    gint64 index = zg_model_selected_gap(model, &layer);
    if (index < 0) {
        if (ins->signature && strcmp(ins->signature, "gap") == 0) {
            g_clear_pointer(&ins->signature, g_free);
            ins->built = FALSE;
            fill_inspector(ins);
        }
        return;
    }
    const char *next = ins->in_a ? "b" : "a";
    GtkWidget *old = gtk_stack_get_child_by_name(GTK_STACK(ins->slots), next);
    if (old) gtk_stack_remove(GTK_STACK(ins->slots), old);
    gtk_stack_add_named(GTK_STACK(ins->slots), zg_scrolled_new(build_gap_page(ins, layer, index)), next);
    gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
    ins->in_a = !ins->in_a;
    g_clear_pointer(&ins->signature, g_free);
    ins->signature = g_strdup("gap");
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
    /* A new slice with a gap selected: the same gap again, by its place,
     * or the news that it is closed. */
    if (event == ZS_EVENT_SLICED && ins->signature && strcmp(ins->signature, "gap") == 0) {
        const zs_gap *gaps = NULL;
        size_t n = 0;
        gint64 found = -1;
        double best = 1.0; /* mm */
        if (zs_app_layer_gaps(zg_model_core(model), (size_t)ins->gap_layer, &gaps, &n, NULL, NULL) == ZS_OK) {
            for (size_t i = 0; i < n; i++) {
                double d = hypot(gaps[i].x - ins->gap_x, gaps[i].y - ins->gap_y);
                if (d < best) {
                    best = d;
                    found = (gint64)i;
                }
            }
        }
        if (found >= 0) {
            /* A new page for it, also with the same index: the clear
             * first, with no line page between. */
            g_free(ins->signature);
            ins->signature = g_strdup("gap-wait");
            zg_model_select_gap(model, -1, -1);
            zg_model_select_gap(model, ins->gap_layer, found);
        } else {
            GtkWidget *grid = zg_grid_new();
            int row = 0;
            GtkWidget *t = zg_grid_add_heading(grid, &row, "The gap is closed");
            gtk_widget_add_css_class(t, "title-4");
            char *text = g_strdup_printf("Layer %lld has no gap at %.1f, %.1f mm after this change.", (long long)ins->gap_layer + 1, ins->gap_x, ins->gap_y);
            gtk_grid_attach(GTK_GRID(grid), zg_wrapped_label_new(text), 0, row++, 3, 1);
            g_free(text);
            const char *next = ins->in_a ? "b" : "a";
            GtkWidget *old = gtk_stack_get_child_by_name(GTK_STACK(ins->slots), next);
            if (old) gtk_stack_remove(GTK_STACK(ins->slots), old);
            gtk_stack_add_named(GTK_STACK(ins->slots), zg_scrolled_new(grid), next);
            gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
            ins->in_a = !ins->in_a;
            g_clear_pointer(&ins->signature, g_free);
            ins->signature = g_strdup("gap-closed");
            zg_model_select_gap(model, -1, -1);
        }
    }
}

/* This page shows again: its scope comes back. */
static void on_panel_page(GObject *stack, GParamSpec *pspec, gpointer data) {
    Inspector *ins = data;
    if (ins->built && zg_model_selected(ins->model) >= 0) apply_scope(ins);
}

static void inspector_free(gpointer data) {
    Inspector *ins = data;
    g_signal_handlers_disconnect_by_data(ins->model, ins);
    if (ins->stack) g_signal_handlers_disconnect_by_data(ins->stack, ins);
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
    g_signal_connect(model, "segment-changed", G_CALLBACK(on_segment_measure), ins);
    g_signal_connect(model, "picked", G_CALLBACK(on_picked), ins);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), ins);
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), ins);
    g_signal_connect(model, "gaps-changed", G_CALLBACK(on_gaps_changed), ins);
    g_signal_connect(panel_stack, "notify::visible-child", G_CALLBACK(on_panel_page), ins);
    return ins->slots;
}

const char *zg_inspector_title(GtkWidget *inspector) {
    Inspector *ins = g_object_get_data(G_OBJECT(inspector), "zg-inspector");
    if (ins && ins->signature && strcmp(ins->signature, "part") == 0) return "Selected part";
    if (ins && ins->signature && g_str_has_prefix(ins->signature, "gap")) return "Selected gap";
    return "Selected line";
}
