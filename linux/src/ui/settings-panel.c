/* settings-panel.c: see settings-panel.h.
 *
 * Each row has a label and an editor. The editor depends on the kind of the
 * setting:
 *   number, integer: an entry with the unit after it. The value goes to
 *     the core after a short pause in the typing, on Enter, and when the
 *     focus leaves. Up and Down step the value (Shift: 10 steps, Ctrl: a
 *     tenth of a step). A drag on the label to the left or the right also
 *     changes the value. A ratio (unit "%") shows as a percentage: the core
 *     value 0.5 shows as 50.
 *   one-line text: an entry, set on Enter or when the focus leaves it
 *   boolean: a switch
 *   choice: a drop-down
 *   multi-line text (G-code): a text view, set when the focus leaves it
 *
 * A value that the core rejects gets the "error" style, and the tooltip
 * says why. Each set starts a new slice (zg_model_set). Each editor follows
 * the "setting-changed" signal of the model, so all editors of a setting
 * show the same value.
 *
 * The "Selected" page is the inspector. After a new slice of the same line,
 * it changes the text in place and keeps its rows: the page does not move,
 * the editor with the focus keeps it, and the tab stays. Only a click on a
 * line (the "picked" signal) opens the page.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include <math.h>
#include <stdlib.h>
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

/* The pause before a value goes to the core, in ms: after typing, and
 * during a drag on a label. */
enum { LIVE_DELAY_MS = 350, SCRUB_DELAY_MS = 60 };

static ZgModel *model_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-model");
}

static const char *key_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-key");
}

static int kind_of(GtkWidget *w) {
    return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "zg-kind"));
}

static gboolean is_number(GtkWidget *w) {
    return kind_of(w) == ZS_SETTING_NUMBER || kind_of(w) == ZS_SETTING_INTEGER;
}

static gboolean is_percent(GtkWidget *w) {
    return is_number(w) && g_strcmp0(g_object_get_data(G_OBJECT(w), "zg-unit"), "%") == 0;
}

static gboolean parses_as_number(const char *text) {
    char *end = NULL;
    g_ascii_strtod(text, &end);
    return text[0] && end && *end == 0;
}

/* Writes a number with no more digits than it needs, with a dot as the
 * decimal mark in any locale. */
static void format_number(char *buf, size_t cap, double v) {
    g_ascii_formatd(buf, cap, "%.6g", v);
}

/* The text of the core value as the editor shows it (a ratio times 100).
 * Free with g_free. */
static char *to_display(GtkWidget *editor, const char *core_value) {
    if (!is_percent(editor) || !parses_as_number(core_value)) return g_strdup(core_value);
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    format_number(buf, sizeof buf, g_ascii_strtod(core_value, NULL) * 100);
    return g_strdup(buf);
}

/* The core value of the text in an editor. Free with g_free. */
static char *to_core(GtkWidget *editor, const char *text) {
    if (!is_percent(editor) || !parses_as_number(text)) return g_strdup(text);
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.10g", g_ascii_strtod(text, NULL) / 100);
    return g_strdup(buf);
}

/* Sends the text of an editor to the core. With `quiet`, a rejected value
 * gets no error style: the user is still typing. Returns TRUE if the core
 * has the value. */
static gboolean commit_value(GtkWidget *editor, const char *text, gboolean quiet) {
    GError *error = NULL;
    char *value = to_core(editor, text);
    char *old = zg_model_get(model_of(editor), key_of(editor));
    gboolean same = g_strcmp0(old, value) == 0;
    if (!same && is_number(editor) && parses_as_number(old) && parses_as_number(value)) {
        same = g_ascii_strtod(old, NULL) == g_ascii_strtod(value, NULL);
    }
    g_free(old);
    gboolean ok = TRUE;
    if (same) {
        gtk_widget_remove_css_class(editor, "error");
    } else if (zg_model_set(model_of(editor), key_of(editor), value, &error)) {
        gtk_widget_remove_css_class(editor, "error");
        gtk_widget_set_tooltip_text(editor, g_object_get_data(G_OBJECT(editor), "zg-doc"));
    } else {
        if (!quiet) {
            gtk_widget_add_css_class(editor, "error");
            gtk_widget_set_tooltip_text(editor, error->message);
        }
        g_error_free(error);
        ok = FALSE;
    }
    g_free(value);
    return ok;
}

static void commit(GtkWidget *editor, const char *text) {
    commit_value(editor, text, FALSE);
}

/* ---- live entries ---- */

static void cancel_live(GtkWidget *entry) {
    guint id = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(entry), "zg-live"));
    if (id) g_source_remove(id);
    g_object_set_data(G_OBJECT(entry), "zg-live", NULL);
}

static gboolean on_live(gpointer data) {
    GtkWidget *entry = data;
    g_object_set_data(G_OBJECT(entry), "zg-live", NULL);
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    /* Half-typed numbers ("", "-", "0.") wait for more typing. */
    if (parses_as_number(text) && text[strlen(text) - 1] != '.') commit_value(entry, text, TRUE);
    return G_SOURCE_REMOVE;
}

static void schedule_live(GtkWidget *entry, guint delay) {
    cancel_live(entry);
    guint id = g_timeout_add(delay, on_live, entry);
    g_object_set_data(G_OBJECT(entry), "zg-live", GUINT_TO_POINTER(id));
}

static void on_entry_changed(GtkEditable *e, gpointer data) {
    GtkWidget *entry = GTK_WIDGET(e);
    /* A change from the code (sync, step, drag) has its own commit. */
    if (g_object_get_data(G_OBJECT(entry), "zg-setting")) return;
    gtk_widget_remove_css_class(entry, "error");
    if (is_number(entry)) schedule_live(entry, LIVE_DELAY_MS);
}

static void set_entry_text(GtkWidget *entry, const char *text) {
    g_object_set_data(G_OBJECT(entry), "zg-setting", GINT_TO_POINTER(1));
    int pos = gtk_editable_get_position(GTK_EDITABLE(entry));
    gtk_editable_set_text(GTK_EDITABLE(entry), text);
    gtk_editable_set_position(GTK_EDITABLE(entry), MIN(pos, (int)strlen(text)));
    g_object_set_data(G_OBJECT(entry), "zg-setting", NULL);
}

static void on_entry_commit(GtkWidget *entry) {
    cancel_live(entry);
    commit(entry, gtk_editable_get_text(GTK_EDITABLE(entry)));
}

static void on_entry_activate(GtkEntry *entry, gpointer data) {
    on_entry_commit(GTK_WIDGET(entry));
}

/* The number of decimal places in a number as text. */
static int decimals_of(const char *text) {
    const char *dot = strchr(text, '.');
    if (!dot) return 0;
    int n = 0;
    for (const char *c = dot + 1; *c >= '0' && *c <= '9'; c++) n++;
    return n;
}

/* Adds `steps` steps to the shown value `base`, and sends it to the core
 * after `delay` ms. A step is one unit of the last decimal place of the
 * value (0.44 steps by 0.01, 150 by 1, 50 % by 1 %), and 1 for an integer.
 * `fine` adds one decimal place. */
static void step_value(GtkWidget *entry, const char *base, double steps, gboolean fine, guint delay) {
    gboolean integer = kind_of(entry) == ZS_SETTING_INTEGER;
    int d = integer ? 0 : decimals_of(base) + (fine ? 1 : 0);
    double v = g_ascii_strtod(base, NULL) + steps * pow(10, -d);
    if (integer) v = MAX(0, round(v));
    char fmt[16], buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_snprintf(fmt, sizeof fmt, "%%.%df", d);
    g_ascii_formatd(buf, sizeof buf, fmt, v);
    set_entry_text(entry, buf);
    schedule_live(entry, delay);
}

static gboolean on_entry_key(GtkEventControllerKey *ctrl, guint key, guint code, GdkModifierType mods, gpointer data) {
    GtkWidget *entry = data;
    if (key != GDK_KEY_Up && key != GDK_KEY_Down && key != GDK_KEY_Page_Up && key != GDK_KEY_Page_Down) return FALSE;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!parses_as_number(text)) return FALSE;
    double steps = (key == GDK_KEY_Up || key == GDK_KEY_Page_Up) ? 1 : -1;
    if ((mods & GDK_SHIFT_MASK) || key == GDK_KEY_Page_Up || key == GDK_KEY_Page_Down) steps *= 10;
    char *base = g_strdup(text);
    step_value(entry, base, steps, (mods & GDK_CONTROL_MASK) != 0, 150);
    g_free(base);
    return TRUE;
}

/* A drag on the label changes the value: one step for each 6 px. */
static void on_scrub_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    GtkWidget *entry = data;
    g_object_set_data_full(G_OBJECT(entry), "zg-scrub-base", g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry))), g_free);
}

static void on_scrub_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    GtkWidget *entry = data;
    const char *base = g_object_get_data(G_OBJECT(entry), "zg-scrub-base");
    if (!base || !parses_as_number(base)) return;
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    double steps = trunc(dx / 6);
    if (mods & GDK_SHIFT_MASK) steps *= 10;
    step_value(entry, base, steps, (mods & GDK_CONTROL_MASK) != 0, SCRUB_DELAY_MS);
}

static void on_scrub_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    GtkWidget *entry = data;
    /* The last value goes to the core at once. */
    if (g_object_get_data(G_OBJECT(entry), "zg-live")) {
        cancel_live(entry);
        on_live(entry);
    }
}

static void add_scrub(GtkWidget *label, GtkWidget *entry) {
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_scrub_begin), entry);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_scrub_update), entry);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_scrub_end), entry);
    gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(drag));
    gtk_widget_set_cursor_from_name(label, "ew-resize");
}

/* ---- the other editors ---- */

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

/* Shows the value of the core in an editor, after a set from an other
 * editor of the same setting. An editor with the focus keeps its text. */
static void show_value(GtkWidget *editor) {
    char *value = zg_model_get(model_of(editor), key_of(editor));
    if (GTK_IS_SWITCH(editor)) {
        gboolean on = strcmp(value, "true") == 0;
        if (gtk_switch_get_active(GTK_SWITCH(editor)) != on) gtk_switch_set_active(GTK_SWITCH(editor), on);
    } else if (GTK_IS_DROP_DOWN(editor)) {
        GListModel *items = gtk_drop_down_get_model(GTK_DROP_DOWN(editor));
        for (guint i = 0; i < g_list_model_get_n_items(items); i++) {
            GtkStringObject *s = g_list_model_get_item(items, i);
            gboolean match = strcmp(gtk_string_object_get_string(s), value) == 0;
            g_object_unref(s);
            if (match && gtk_drop_down_get_selected(GTK_DROP_DOWN(editor)) != i) gtk_drop_down_set_selected(GTK_DROP_DOWN(editor), i);
        }
    } else if (GTK_IS_TEXT_VIEW(editor)) {
        if (!gtk_widget_has_focus(editor)) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor)), value, -1);
    } else if (GTK_IS_EDITABLE(editor)) {
        /* GtkEntry has its focus on an inner text widget. */
        GtkRoot *root = gtk_widget_get_root(editor);
        GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
        gboolean typing = focus && (focus == editor || gtk_widget_is_ancestor(focus, editor));
        char *shown = to_display(editor, value);
        if (!typing && strcmp(gtk_editable_get_text(GTK_EDITABLE(editor)), shown) != 0) set_entry_text(editor, shown);
        g_free(shown);
    }
    g_free(value);
}

static void on_setting_changed(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *editor = data;
    if (g_strcmp0(key, key_of(editor)) == 0) show_value(editor);
}

static void tag(GtkWidget *editor, ZgModel *model, const zs_setting_info *info) {
    g_object_set_data(G_OBJECT(editor), "zg-model", model);
    g_object_set_data(G_OBJECT(editor), "zg-key", (gpointer)info->name);
    g_object_set_data(G_OBJECT(editor), "zg-doc", (gpointer)info->doc);
    g_object_set_data(G_OBJECT(editor), "zg-kind", GINT_TO_POINTER(info->kind));
    g_object_set_data(G_OBJECT(editor), "zg-unit", (gpointer)info->unit);
    gtk_widget_set_tooltip_text(editor, info->doc);
    /* The handler goes away with the editor. */
    g_signal_connect_object(model, "setting-changed", G_CALLBACK(on_setting_changed), editor, 0);
}

static void add_focus_commit(GtkWidget *editor) {
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(on_focus_leave), editor);
    gtk_widget_add_controller(editor, focus);
}

static void on_editor_destroy(GtkWidget *editor, gpointer data) {
    cancel_live(editor);
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
    default: {
        editor = gtk_entry_new();
        tag(editor, model, info);
        char *shown = to_display(editor, value);
        gtk_editable_set_text(GTK_EDITABLE(editor), shown);
        g_free(shown);
        gtk_editable_set_width_chars(GTK_EDITABLE(editor), info->kind == ZS_SETTING_TEXT ? 14 : 7);
        if (info->kind != ZS_SETTING_TEXT) {
            gtk_entry_set_input_purpose(GTK_ENTRY(editor), GTK_INPUT_PURPOSE_NUMBER);
            gtk_entry_set_alignment(GTK_ENTRY(editor), 1.0);
            GtkEventController *keys = gtk_event_controller_key_new();
            g_signal_connect(keys, "key-pressed", G_CALLBACK(on_entry_key), editor);
            gtk_widget_add_controller(editor, keys);
        }
        g_signal_connect(editor, "activate", G_CALLBACK(on_entry_activate), NULL);
        g_signal_connect(editor, "changed", G_CALLBACK(on_entry_changed), NULL);
        g_signal_connect(editor, "destroy", G_CALLBACK(on_editor_destroy), NULL);
        add_focus_commit(editor);
        break;
    }
    }
    gtk_widget_set_valign(editor, GTK_ALIGN_CENTER);
    g_free(value);
    return editor;
}

static GtkWidget *new_grid(void) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    gtk_widget_set_margin_start(grid, 12);
    gtk_widget_set_margin_end(grid, 12);
    gtk_widget_set_margin_top(grid, 12);
    gtk_widget_set_margin_bottom(grid, 12);
    return grid;
}

/* Adds the label, the editor, and the unit of one setting to a grid. The
 * unit has its own column, so the editors line up. */
static void add_row(GtkWidget *grid, int *row, ZgModel *model, const zs_setting_info *info, gboolean with_group) {
    char *label_text = g_markup_escape_text(info->label, -1);
    char *text = with_group ? g_strdup_printf("%s <span alpha=\"55%%\" size=\"small\">%s</span>", label_text, info->group)
                            : g_strdup(label_text);
    g_free(label_text);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), text);
    g_free(text);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_widget_set_tooltip_text(label, info->doc);
    GtkWidget *editor = make_editor(model, info);
    gboolean number = info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER;
    if (number) add_scrub(label, editor);
    if (info->kind == ZS_SETTING_TEXT && info->multiline) {
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 120);
        gtk_widget_add_css_class(scroll, "frame");
        gtk_grid_attach(GTK_GRID(grid), label, 0, (*row)++, 3, 1);
        gtk_grid_attach(GTK_GRID(grid), scroll, 0, (*row)++, 3, 1);
        return;
    }
    gtk_grid_attach(GTK_GRID(grid), label, 0, *row, 1, 1);
    if (number) {
        gtk_grid_attach(GTK_GRID(grid), editor, 1, *row, 1, 1);
        GtkWidget *unit = gtk_label_new(info->unit);
        gtk_widget_add_css_class(unit, "dim-label");
        gtk_widget_add_css_class(unit, "zg-unit");
        gtk_label_set_xalign(GTK_LABEL(unit), 0);
        gtk_grid_attach(GTK_GRID(grid), unit, 2, (*row)++, 1, 1);
    } else {
        gtk_widget_set_halign(editor, GTK_ALIGN_END);
        gtk_grid_attach(GTK_GRID(grid), editor, 1, (*row)++, 2, 1);
    }
}

static GtkWidget *add_heading(GtkWidget *grid, int *row, const char *text) {
    GtkWidget *heading = gtk_label_new(text);
    gtk_widget_add_css_class(heading, "heading");
    gtk_widget_set_halign(heading, GTK_ALIGN_START);
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_label_set_wrap(GTK_LABEL(heading), TRUE);
    gtk_widget_set_margin_top(heading, *row == 0 ? 0 : 12);
    gtk_grid_attach(GTK_GRID(grid), heading, 0, (*row)++, 3, 1);
    return heading;
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
    GtkWidget *stack;   /* the page stack of the panel */
    GtkWidget *slots;   /* two slots, "a" and "b", for a crossfade */
    gboolean in_a;      /* the visible slot is "a" */
    gboolean built;     /* the visible slot has content */
    char *signature;    /* the title and the setting names of the rows */
    /* The parts that change in place. */
    GtkWidget *title;
    GtkWidget *stat_value[3];
    GtkWidget *stat_note;
    GtkWidget *explain;
} Inspector;

static gboolean find_setting(const char *name, zs_setting_info *out) {
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        if (zs_setting_get_info(i, out) == ZS_OK && strcmp(out->name, name) == 0) return TRUE;
    }
    return FALSE;
}

static const char *stat_names[3] = {"planned speed", "real speed", "flow"};

/* The speed summary: three numbers with a caption under each. */
static GtkWidget *make_stats(Inspector *ins) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_set_homogeneous(GTK_BOX(row), TRUE);
    for (int i = 0; i < 3; i++) {
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_add_css_class(box, "zg-stat");
        ins->stat_value[i] = gtk_label_new("");
        gtk_widget_add_css_class(ins->stat_value[i], "zg-stat-value");
        GtkWidget *caption = gtk_label_new(stat_names[i]);
        gtk_widget_add_css_class(caption, "zg-stat-caption");
        gtk_label_set_ellipsize(GTK_LABEL(caption), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(box), ins->stat_value[i]);
        gtk_box_append(GTK_BOX(box), caption);
        gtk_box_append(GTK_BOX(row), box);
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
    gboolean slowed = info->speed < info->planned_speed * 0.98;
    if (slowed) gtk_widget_add_css_class(ins->stat_value[1], "warning");
    else gtk_widget_remove_css_class(ins->stat_value[1], "warning");
    /* The note keeps its space, so the rows under it do not move. */
    gtk_widget_set_opacity(ins->stat_note, slowed ? 1 : 0);
}

static void show_text(Inspector *ins, const zs_inspect *info) {
    char *title = g_strdup_printf("%s · layer %zu", info->title, info->layer + 1);
    gtk_label_set_text(GTK_LABEL(ins->title), title);
    g_free(title);
    gtk_label_set_text(GTK_LABEL(ins->explain), info->explain);
    show_stats(ins, info);
}

static GtkWidget *wrapped_label(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_set_hexpand(l, TRUE);
    return l;
}

/* Builds the rows for a selection. */
static GtkWidget *build_inspector(Inspector *ins, const zs_inspect *info) {
    GtkWidget *grid = new_grid();
    int row = 0;
    if (!info) {
        GtkWidget *hint = wrapped_label("Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), hint, 0, row++, 3, 1);
        return grid;
    }
    ins->title = add_heading(grid, &row, "");
    gtk_widget_add_css_class(ins->title, "title-4");
    gtk_grid_attach(GTK_GRID(grid), make_stats(ins), 0, row++, 3, 1);
    ins->stat_note = wrapped_label("This layer is short, so it prints slower to cool (filament minimum layer time).");
    gtk_widget_add_css_class(ins->stat_note, "zg-note");
    gtk_grid_attach(GTK_GRID(grid), ins->stat_note, 0, row++, 3, 1);

    char **names = g_strsplit(info->settings, "\n", -1);
    for (int i = 0; names[i]; i++) {
        if (g_str_has_prefix(names[i], "# ")) {
            add_heading(grid, &row, names[i] + 2);
            continue;
        }
        zs_setting_info s;
        if (find_setting(names[i], &s)) add_row(grid, &row, ins->model, &s, TRUE);
    }
    g_strfreev(names);

    GtkWidget *more = gtk_expander_new("How these values come about");
    gtk_widget_set_margin_top(more, 12);
    /* Not selectable: a selectable label can take the focus, and GTK then
     * selects all of its text. */
    ins->explain = wrapped_label("");
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
    gtk_stack_add_named(GTK_STACK(ins->slots), scrolled(content), next);
    gtk_stack_set_visible_child_name(GTK_STACK(ins->slots), next);
    ins->in_a = !ins->in_a;
    ins->built = TRUE;
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    fill_inspector(data);
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
    g_free(ins->signature);
    g_free(ins);
}

GtkWidget *zg_settings_panel_new(ZgModel *model) {
    GtkWidget *stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(stack), 120);
    Inspector *ins = g_new0(Inspector, 1);
    ins->model = model;
    ins->stack = stack;
    ins->slots = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(ins->slots), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(ins->slots), 140);
    gtk_widget_add_css_class(ins->slots, "zg-inspector");
    g_object_set_data_full(G_OBJECT(ins->slots), "zg-inspector", ins, inspector_free);
    fill_inspector(ins);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), ins);
    g_signal_connect(model, "picked", G_CALLBACK(on_picked), ins);
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), ins);
    gtk_stack_add_titled(GTK_STACK(stack), ins->slots, "selected", "Selected");
    for (size_t i = 0; i < G_N_ELEMENTS(pages); i++) {
        gtk_stack_add_titled(GTK_STACK(stack), make_page(model, pages[i].group), pages[i].group, pages[i].title);
    }
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(switcher, 8);
    gtk_widget_set_margin_bottom(switcher, 4);
    /* The tabs scroll when the panel is narrow, so the panel can be as
     * narrow as the user wants. */
    GtkWidget *tabs = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tabs), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tabs), switcher);
    gtk_scrolled_window_set_propagate_natural_width(GTK_SCROLLED_WINDOW(tabs), TRUE);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(box), tabs);
    gtk_box_append(GTK_BOX(box), stack);
    gtk_widget_set_size_request(box, 220, -1);
    return box;
}
