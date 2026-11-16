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
 * The panel has two pages: "Selected", the inspector, and "Settings", a
 * browser of all settings in three columns.
 *
 * The "Selected" page is the inspector. After a new slice of the same line,
 * it changes the text in place and keeps its rows: the page does not move,
 * the editor with the focus keeps it, and the tab stays. Only a click on a
 * line (the "picked" signal) opens the page.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include "colors.h"

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

/* An editor of the inspector: it follows the scope of the model (all
 * layers, or the layers of the selection). */
static gboolean is_scoped(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-scoped") != NULL;
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
/* A line width of 0 means "from the nozzle": the editors show "auto". */
static gboolean is_auto(GtkWidget *editor) {
    return g_str_has_suffix(key_of(editor), "line_width");
}

static char *to_display(GtkWidget *editor, const char *core_value) {
    if (is_auto(editor) && parses_as_number(core_value) && g_ascii_strtod(core_value, NULL) == 0) return g_strdup("auto");
    if (!is_percent(editor) || !parses_as_number(core_value)) return g_strdup(core_value);
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    format_number(buf, sizeof buf, g_ascii_strtod(core_value, NULL) * 100);
    return g_strdup(buf);
}

/* The core value of the text in an editor. Free with g_free. */
static char *to_core(GtkWidget *editor, const char *text) {
    if (is_auto(editor) && g_ascii_strcasecmp(text, "auto") == 0) return g_strdup("0");
    if (!is_percent(editor) || !parses_as_number(text)) return g_strdup(text);
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.10g", g_ascii_strtod(text, NULL) / 100);
    return g_strdup(buf);
}

static const zs_setting_info *info_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-info");
}

/* A range in the units that the editors show (a ratio as a percentage). */
static char *range_text(const zs_setting_info *info, double lo, double hi) {
    double k = strcmp(info->unit, "%") == 0 ? 100 : 1;
    char a[G_ASCII_DTOSTR_BUF_SIZE], b[G_ASCII_DTOSTR_BUF_SIZE];
    format_number(a, sizeof a, lo * k);
    format_number(b, sizeof b, hi * k);
    return g_strdup_printf("%s to %s %s", a, b, info->unit);
}

/* A value out of the usual range (the slider range) is valid, but the
 * editor says that it is unusual. */
static void show_unusual(GtkWidget *editor) {
    const zs_setting_info *info = info_of(editor);
    if (!info || !is_number(editor) || !(info->slider_max > info->slider_min)) return;
    char *value = zg_model_get_for(model_of(editor), key_of(editor), is_scoped(editor));
    gboolean unusual = parses_as_number(value) &&
                       (g_ascii_strtod(value, NULL) < info->slider_min - 1e-9 || g_ascii_strtod(value, NULL) > info->slider_max + 1e-9);
    g_free(value);
    if (unusual == gtk_widget_has_css_class(editor, "zg-unusual")) return;
    if (unusual) {
        gtk_widget_add_css_class(editor, "zg-unusual");
        char *range = range_text(info, info->slider_min, info->slider_max);
        char *tip = g_strdup_printf("An unusual value: most prints use %s.\n\n%s", range, info->doc);
        gtk_widget_set_tooltip_text(editor, tip);
        g_free(tip);
        g_free(range);
    } else {
        gtk_widget_remove_css_class(editor, "zg-unusual");
        gtk_widget_set_tooltip_text(editor, info->doc);
    }
}

/* Sends the text of an editor to the core. With `quiet`, a rejected value
 * gets no error style: the user is still typing. Returns TRUE if the core
 * has the value. */
static gboolean commit_value(GtkWidget *editor, const char *text, gboolean quiet) {
    GError *error = NULL;
    char *value = to_core(editor, text);
    /* Out of the hard limits: say what the limits are. */
    const zs_setting_info *info = info_of(editor);
    if (info && is_number(editor) && info->limit_max > info->limit_min && parses_as_number(value)) {
        double v = g_ascii_strtod(value, NULL);
        if (v < info->limit_min - 1e-12 || v > info->limit_max + 1e-12) {
            if (!quiet) {
                char *range = range_text(info, info->limit_min, info->limit_max);
                char *tip = g_strdup_printf("Out of the limits: use %s.", range);
                gtk_widget_add_css_class(editor, "error");
                gtk_widget_set_tooltip_text(editor, tip);
                g_free(tip);
                g_free(range);
            }
            g_free(value);
            return FALSE;
        }
    }
    char *old = zg_model_get_for(model_of(editor), key_of(editor), is_scoped(editor));
    gboolean same = g_strcmp0(old, value) == 0;
    if (!same && is_number(editor) && parses_as_number(old) && parses_as_number(value)) {
        same = g_ascii_strtod(old, NULL) == g_ascii_strtod(value, NULL);
    }
    g_free(old);
    gboolean ok = TRUE;
    if (same) {
        gtk_widget_remove_css_class(editor, "error");
    } else if (zg_model_set_for(model_of(editor), key_of(editor), value, is_scoped(editor), &error)) {
        gtk_widget_remove_css_class(editor, "error");
        gtk_widget_set_tooltip_text(editor, g_object_get_data(G_OBJECT(editor), "zg-doc"));
        show_unusual(editor);
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

/* ---- sliders ---- */

/* The slider of a number: it moves the value in the entry, and the value
 * goes to the core at once (the model slices the newest value when the
 * running slice ends). */
static void on_slider(GtkRange *range, gpointer data) {
    GtkWidget *entry = data;
    if (g_object_get_data(G_OBJECT(range), "zg-setting")) return;
    /* Snap to the step of the slider. */
    double step = gtk_adjustment_get_step_increment(gtk_range_get_adjustment(range));
    double lo = gtk_adjustment_get_lower(gtk_range_get_adjustment(range));
    double v = lo + round((gtk_range_get_value(range) - lo) / step) * step;
    int d = step >= 1 ? 0 : (int)ceil(-log10(step) - 1e-9);
    char fmt[16], buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_snprintf(fmt, sizeof fmt, "%%.%df", d);
    g_ascii_formatd(buf, sizeof buf, fmt, v);
    /* The same value as before: no new slice. */
    if (strcmp(buf, gtk_editable_get_text(GTK_EDITABLE(entry))) == 0) return;
    set_entry_text(entry, buf);
    /* No wait: the model queues the value while a slice runs. */
    cancel_live(entry);
    commit_value(entry, buf, TRUE);
}

/* Moves the slider to the value of the entry, after a change from an other
 * place. */
static void sync_slider(GtkWidget *entry) {
    GtkWidget *slider = g_object_get_data(G_OBJECT(entry), "zg-slider");
    if (!slider) return;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!parses_as_number(text)) return;
    g_object_set_data(G_OBJECT(slider), "zg-setting", GINT_TO_POINTER(1));
    gtk_range_set_value(GTK_RANGE(slider), g_ascii_strtod(text, NULL));
    g_object_set_data(G_OBJECT(slider), "zg-setting", NULL);
}

static GtkWidget *make_slider(const zs_setting_info *info, GtkWidget *entry) {
    double scale = strcmp(info->unit, "%") == 0 ? 100 : 1;
    double lo = info->slider_min * scale, hi = info->slider_max * scale;
    double step = info->kind == ZS_SETTING_INTEGER ? 1 : info->slider_step * scale;
    if (!(step > 0)) step = pow(10, floor(log10((hi - lo) / 100)));
    GtkWidget *slider = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step);
    gtk_scale_set_draw_value(GTK_SCALE(slider), FALSE);
    /* A tick at the default value. */
    if (parses_as_number(info->default_value)) {
        double d = g_ascii_strtod(info->default_value, NULL) * scale;
        if (d >= lo && d <= hi) gtk_scale_add_mark(GTK_SCALE(slider), d, GTK_POS_BOTTOM, NULL);
    }
    gtk_widget_set_hexpand(slider, TRUE);
    gtk_widget_add_css_class(slider, "zg-slider");
    gtk_widget_set_tooltip_text(slider, info->doc);
    g_object_set_data(G_OBJECT(entry), "zg-slider", slider);
    sync_slider(entry);
    g_signal_connect(slider, "value-changed", G_CALLBACK(on_slider), entry);
    return slider;
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
    char *value = zg_model_get_for(model_of(editor), key_of(editor), is_scoped(editor));
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
        show_unusual(editor);
        /* A slider in a drag keeps its place under the pointer. */
        GtkWidget *slider = g_object_get_data(G_OBJECT(editor), "zg-slider");
        if (slider && !(gtk_widget_get_state_flags(slider) & GTK_STATE_FLAG_ACTIVE)) sync_slider(editor);
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
    zs_setting_info *copy = g_new(zs_setting_info, 1);
    *copy = *info;
    g_object_set_data_full(G_OBJECT(editor), "zg-info", copy, g_free);
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

static GtkWidget *make_editor(ZgModel *model, const zs_setting_info *info, gboolean scoped) {
    char *value = zg_model_get_for(model, info->name, scoped);
    GtkWidget *editor = NULL;
    switch (info->kind) {
    case ZS_SETTING_BOOLEAN:
        editor = gtk_switch_new();
        if (scoped) g_object_set_data(G_OBJECT(editor), "zg-scoped", GINT_TO_POINTER(1));
        gtk_switch_set_active(GTK_SWITCH(editor), strcmp(value, "true") == 0);
        gtk_widget_set_halign(editor, GTK_ALIGN_END);
        tag(editor, model, info);
        g_signal_connect(editor, "notify::active", G_CALLBACK(on_switch), NULL);
        break;
    case ZS_SETTING_CHOICE: {
        char **choices = g_strsplit(info->choices, "\n", -1);
        editor = gtk_drop_down_new_from_strings((const char *const *)choices);
        if (scoped) g_object_set_data(G_OBJECT(editor), "zg-scoped", GINT_TO_POINTER(1));
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
            if (scoped) g_object_set_data(G_OBJECT(editor), "zg-scoped", GINT_TO_POINTER(1));
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
        if (scoped) g_object_set_data(G_OBJECT(editor), "zg-scoped", GINT_TO_POINTER(1));
        tag(editor, model, info);
        char *shown = to_display(editor, value);
        gtk_editable_set_text(GTK_EDITABLE(editor), shown);
        g_free(shown);
        gtk_editable_set_width_chars(GTK_EDITABLE(editor), info->kind == ZS_SETTING_TEXT ? 14 : 6);
        if (info->kind != ZS_SETTING_TEXT) gtk_editable_set_max_width_chars(GTK_EDITABLE(editor), 6);
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
    show_unusual(editor);
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
/* The flags of add_row. ROW_COMPACT: one line for each setting (the
 * label does not wrap, the group is in the tooltip), and the slider opens
 * under the row only while the row has the focus. */
enum { ROW_COMPACT = 1 };

/* The widgets of one row, for a filter (see Inspector). */
typedef struct {
    GtkWidget *widgets[4];
    char *needle; /* the label in lower case */
} Row;

static void row_free(gpointer data) {
    Row *r = data;
    g_free(r->needle);
    g_free(r);
}

/* A compact row shows its slider while the entry or the slider has the
 * focus. The check runs after the focus moves (in an idle), so a click
 * from the entry on the slider keeps the slider open. */
static gboolean update_reveal(gpointer data) {
    GtkWidget *revealer = data;
    GtkWidget *entry = g_object_get_data(G_OBJECT(revealer), "zg-entry");
    GtkWidget *slider = gtk_revealer_get_child(GTK_REVEALER(revealer));
    GtkRoot *root = gtk_widget_get_root(revealer);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    gboolean open = focus && (focus == entry || focus == slider || gtk_widget_is_ancestor(focus, entry) ||
                              gtk_widget_is_ancestor(focus, slider));
    open = open || (gtk_widget_get_state_flags(slider) & GTK_STATE_FLAG_ACTIVE);
    gtk_revealer_set_reveal_child(GTK_REVEALER(revealer), open);
    g_object_unref(revealer);
    return G_SOURCE_REMOVE;
}

static void on_row_focus(GtkEventControllerFocus *ctrl, gpointer data) {
    g_idle_add(update_reveal, g_object_ref(data));
}

static void watch_focus(GtkWidget *w, GtkWidget *revealer) {
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_row_focus), revealer);
    g_signal_connect(focus, "leave", G_CALLBACK(on_row_focus), revealer);
    gtk_widget_add_controller(w, focus);
}

/* The scope look of an inspector row: in a layer scope, a setting for the
 * whole print is off, and a setting with an override of this layer has
 * the accent color and a reset button. */
static void show_scope(GtkWidget *editor) {
    ZgModel *model = model_of(editor);
    const zs_setting_info *info = info_of(editor);
    GtkWidget *label = g_object_get_data(G_OBJECT(editor), "zg-label");
    GtkWidget *reset = g_object_get_data(G_OBJECT(editor), "zg-reset");
    double z_min = 0;
    gboolean layer_scope = zg_model_scope(model, &z_min, NULL, NULL);
    /* The whole part: the project and filament settings. Some layers: the
     * settings that can change from layer to layer. */
    gboolean whole = z_min <= -1e5;
    gboolean usable = !layer_scope || (info && (whole ? (strcmp(info->group, "project") == 0 || strcmp(info->group, "filament") == 0)
                                                      : info->per_layer));
    gtk_widget_set_sensitive(editor, usable);
    if (label) gtk_widget_set_sensitive(label, usable);
    gboolean over = layer_scope && zg_model_overridden(model, key_of(editor));
    if (label) {
        if (over) gtk_widget_add_css_class(label, "zg-overridden");
        else gtk_widget_remove_css_class(label, "zg-overridden");
    }
    if (reset) {
        gtk_widget_set_opacity(reset, over ? 1 : 0);
        gtk_widget_set_sensitive(reset, over);
    }
    if (!usable) {
        gtk_widget_set_tooltip_text(editor, whole ? "A printer setting: change it in the Settings page."
                                                  : "A setting for the whole part: it cannot change for some layers. Set \"Change for\" to This part.");
    }
}

static void on_scope_changed(ZgModel *model, gpointer data) {
    GtkWidget *editor = data;
    show_scope(editor);
    show_value(editor);
}

static void on_scope_setting(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *editor = data;
    if (g_strcmp0(key, key_of(editor)) == 0) show_scope(editor);
}

static void on_reset_override(GtkButton *button, gpointer data) {
    GtkWidget *editor = data;
    zg_model_clear_override(model_of(editor), key_of(editor));
}

static Row *add_row(GtkWidget *grid, int *row, ZgModel *model, const zs_setting_info *info, int flags) {
    gboolean compact = flags & ROW_COMPACT;
    GtkWidget *label = gtk_label_new(info->label);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (compact) {
        gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        char *tip = g_strdup_printf("%s (%s setting)\n\n%s", info->label, info->group, info->doc);
        gtk_widget_set_tooltip_text(label, tip);
        g_free(tip);
    } else {
        gtk_label_set_wrap(GTK_LABEL(label), TRUE);
        gtk_widget_set_tooltip_text(label, info->doc);
    }
    Row *r = g_new0(Row, 1);
    r->needle = g_utf8_strdown(info->label, -1);
    r->widgets[0] = label;
    GtkWidget *editor = make_editor(model, info, compact);
    if (compact) gtk_widget_add_css_class(editor, "zg-compact");
    gboolean number = info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER;
    if (number) add_scrub(label, editor);
    if (info->kind == ZS_SETTING_TEXT && info->multiline) {
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 120);
        gtk_widget_add_css_class(scroll, "frame");
        gtk_grid_attach(GTK_GRID(grid), label, 0, (*row)++, 3, 1);
        gtk_grid_attach(GTK_GRID(grid), scroll, 0, (*row)++, 3, 1);
        r->widgets[1] = scroll;
        return r;
    }
    gtk_grid_attach(GTK_GRID(grid), label, 0, *row, 1, 1);
    r->widgets[1] = editor;
    if (compact) {
        /* The scope: a reset button for an override of this layer. */
        GtkWidget *reset = gtk_button_new_from_icon_name("edit-undo-symbolic");
        gtk_widget_add_css_class(reset, "flat");
        gtk_widget_add_css_class(reset, "zg-reset");
        gtk_widget_set_tooltip_text(reset, "Remove the change for these layers: use the value for all layers.");
        gtk_widget_set_valign(reset, GTK_ALIGN_CENTER);
        g_signal_connect(reset, "clicked", G_CALLBACK(on_reset_override), editor);
        gtk_grid_attach(GTK_GRID(grid), reset, 3, *row, 1, 1);
        g_object_set_data(G_OBJECT(editor), "zg-label", label);
        g_object_set_data(G_OBJECT(editor), "zg-reset", reset);
        g_signal_connect_object(model, "scope-changed", G_CALLBACK(on_scope_changed), editor, 0);
        g_signal_connect_object(model, "setting-changed", G_CALLBACK(on_scope_setting), editor, 0);
        show_scope(editor);
    }
    if (number) {
        gtk_grid_attach(GTK_GRID(grid), editor, 1, *row, 1, 1);
        GtkWidget *unit = gtk_label_new(info->unit);
        gtk_widget_add_css_class(unit, "dim-label");
        gtk_widget_add_css_class(unit, "zg-unit");
        gtk_label_set_xalign(GTK_LABEL(unit), 0);
        gtk_grid_attach(GTK_GRID(grid), unit, 2, (*row)++, 1, 1);
        r->widgets[2] = unit;
        if (info->slider_max > info->slider_min) {
            GtkWidget *slider = make_slider(info, editor);
            if (compact) {
                GtkWidget *revealer = gtk_revealer_new();
                gtk_revealer_set_transition_type(GTK_REVEALER(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN);
                gtk_revealer_set_transition_duration(GTK_REVEALER(revealer), 120);
                gtk_revealer_set_child(GTK_REVEALER(revealer), slider);
                g_object_set_data(G_OBJECT(revealer), "zg-entry", editor);
                watch_focus(editor, revealer);
                watch_focus(slider, revealer);
                gtk_grid_attach(GTK_GRID(grid), revealer, 0, (*row)++, 3, 1);
                r->widgets[3] = revealer;
            } else {
                gtk_grid_attach(GTK_GRID(grid), slider, 0, (*row)++, 3, 1);
                r->widgets[3] = slider;
            }
        }
    } else {
        gtk_widget_set_halign(editor, GTK_ALIGN_END);
        gtk_grid_attach(GTK_GRID(grid), editor, 1, (*row)++, 2, 1);
    }
    return r;
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
    GtkWidget *stat_note;  /* a revealer */
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
        Row *r = g_ptr_array_index(ins->rows, i);
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
    gtk_revealer_set_reveal_child(GTK_REVEALER(ins->stat_note), slowed);
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
        zg_model_set_scope(ins->model, TRUE, -1e6, 1e6, 0);
        GtkWidget *hint = wrapped_label("Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), hint, 0, row++, 3, 1);
        return grid;
    }
    ins->title = add_heading(grid, &row, "");
    gtk_widget_add_css_class(ins->title, "zg-insp-title");
    gtk_grid_attach(GTK_GRID(grid), make_stats(ins), 0, row++, 3, 1);
    GtkWidget *note = wrapped_label("This layer is short, so it prints slower to cool (filament minimum layer time).");
    gtk_widget_add_css_class(note, "zg-note");
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
    GtkWidget *scope_note = wrapped_label("Changes here are for this part. The defaults for all prints are in Settings.");
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
    ins->rows = g_ptr_array_new_with_free_func(row_free);
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
        if (!find_setting(names[i], &s)) continue;
        if (!sec_grid) {
            sec_grid = grid;
            sec_row = row;
        }
        Row *r = add_row(sec_grid, &sec_row, ins->model, &s, ROW_COMPACT);
        g_ptr_array_add(ins->rows, r);
        if (sec_grid == grid) row = sec_row;
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
    if (ins->rows) g_ptr_array_free(ins->rows, TRUE);
    if (ins->sections) g_ptr_array_free(ins->sections, TRUE);
    g_free(ins->signature);
    g_free(ins);
}

/* ---- the settings browser ----
 *
 * Three columns, as in a column view of a file manager:
 *   1. the sections, under a heading for each group (Project, Filament,
 *      Machine, Engine), with a search field on top
 *   2. the settings of the section (or the search results), with their
 *      values
 *   3. the selected setting: its editor, its default, its help, and the
 *      lines of the project that it changes. The previews show these lines
 *      clearly and fade the others (zg_model_set_focus).
 * The columns scroll to the side, so a narrow panel shows the last two. */

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
} Browser;

enum { COL1_WIDTH = 165, COL2_WIDTH = 235, COL3_WIDTH = 300 };

static const char *feature_titles[] = {"Outer wall", "Inner wall", "Skin", "Sparse infill",
                                       "Ironing", "Skirt or brim", "Support", "Support interface",
                                       "Seams", "Travel moves", "Retractions"};
enum { N_MARKS = 3 };

static const char *group_title(const char *group) {
    for (size_t i = 0; i < G_N_ELEMENTS(pages); i++) {
        if (strcmp(pages[i].group, group) == 0) return pages[i].title;
    }
    return group;
}

/* The text of a value as the editors show it: a ratio as a percentage. */
static char *display_value(const zs_setting_info *info, const char *value) {
    if (g_str_has_suffix(info->name, "line_width") && parses_as_number(value) && g_ascii_strtod(value, NULL) == 0) return g_strdup("auto");
    if ((info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER) && strcmp(info->unit, "%") == 0 &&
        parses_as_number(value)) {
        char buf[G_ASCII_DTOSTR_BUF_SIZE];
        format_number(buf, sizeof buf, g_ascii_strtod(value, NULL) * 100);
        return g_strdup(buf);
    }
    if (info->kind == ZS_SETTING_TEXT && info->multiline) {
        /* G-code: the first line only. */
        const char *nl = strchr(value, '\n');
        return nl ? g_strdup_printf("%.*s …", (int)(nl - value), value) : g_strdup(value);
    }
    return g_strdup(value);
}

static char *value_with_unit(const zs_setting_info *info, const char *value) {
    char *shown = display_value(info, value);
    /* A count of one: "1 layer", not "1 layers". */
    size_t n = strlen(info->unit);
    gboolean one = strcmp(shown, "1") == 0 && n > 1 && info->unit[n - 1] == 's' && info->kind == ZS_SETTING_INTEGER;
    gboolean no_unit = !info->unit[0] || strcmp(shown, "auto") == 0;
    char *text = no_unit ? g_strdup(shown) : g_strdup_printf("%s %.*s", shown, (int)(one ? n - 1 : n), info->unit);
    g_free(shown);
    return text;
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
    } else if (gtk_editable_get_text(GTK_EDITABLE(b->search))[0]) {
        add_crumb(b, "Search", 1);
    }
    zs_setting_info info;
    if (b->key && find_setting(b->key, &info)) add_crumb(b, info.label, 2);
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
        GtkWidget *l = wrapped_label(text);
        g_free(text);
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(b->effect), l);
        return;
    }
    zs_feature_stats stats[ZS_FEATURE_COUNT];
    gboolean have = zs_app_feature_stats(zg_model_core(b->model), stats) == ZS_OK;
    double total = 0;
    if (have) for (int f = 0; f < ZS_FEATURE_COUNT; f++) total += stats[f].time_s;
    GtkWidget *intro = wrapped_label(e.first_layer_only ? "It changes these lines on the first layer:" : "It changes these lines:");
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
        gtk_box_append(GTK_BOX(b->effect), row);
        shown++;
    }
    if (shown == 0) {
        GtkWidget *l = wrapped_label("This part has none of these lines now.");
        gtk_widget_add_css_class(l, "dim-label");
        gtk_box_append(GTK_BOX(b->effect), l);
    } else {
        GtkWidget *hint = wrapped_label("The preview shows these lines, and the other lines fade.");
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
                    (parses_as_number(value) && parses_as_number(info->default_value) &&
                     g_ascii_strtod(value, NULL) == g_ascii_strtod(info->default_value, NULL));
    char *def = value_with_unit(info, info->default_value);
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
    if (!key || !find_setting(key, info)) {
        g_free(info);
        GtkWidget *hint = wrapped_label("Pick a setting to see what it does and which lines of the project it changes.");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_widget_set_margin_start(hint, 12);
        gtk_widget_set_margin_end(hint, 12);
        gtk_widget_set_margin_top(hint, 12);
        gtk_box_append(GTK_BOX(b->detail), hint);
        /* The focus of the section stays. */
        return;
    }
    b->key = info->name;
    GtkWidget *grid = new_grid();
    int row = 0;
    GtkWidget *title = add_heading(grid, &row, info->label);
    gtk_widget_add_css_class(title, "title-4");
    char *where = g_strdup_printf("%s › %s", group_title(info->group), info->section);
    GtkWidget *path = wrapped_label(where);
    g_free(where);
    gtk_widget_add_css_class(path, "dim-label");
    gtk_widget_add_css_class(path, "caption");
    gtk_grid_attach(GTK_GRID(grid), path, 0, row++, 3, 1);
    add_row(grid, &row, b->model, info, 0);

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

    GtkWidget *doc = wrapped_label(info->doc);
    gtk_widget_set_margin_top(doc, 6);
    gtk_grid_attach(GTK_GRID(grid), doc, 0, row++, 3, 1);

    add_heading(grid, &row, "In your project");
    b->effect = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_grid_attach(GTK_GRID(grid), b->effect, 0, row++, 3, 1);
    fill_effect(b);
    gtk_box_append(GTK_BOX(b->detail), scrolled(grid));

    b->focus = focus_of(info->name, &b->focus_first);
    send_focus(b);
}

/* ---- column 2 ---- */

static void on_row_value_changed(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *label = data;
    const zs_setting_info *info = g_object_get_data(G_OBJECT(label), "zg-info");
    if (strcmp(key, info->name) != 0) return;
    char *value = zg_model_get(model, key);
    char *text = value_with_unit(info, value);
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
    char *text = value_with_unit(info, value);
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
    b->group = group;
    b->section = section;
    fill_settings(b, group, section, NULL);
    /* A new section: its settings come to the front. */
    if (b->crumbs && b->column < 1) show_column(b, 1);
    else update_crumbs(b);
    /* A new section: its lines show, until a setting of it is picked. */
    zs_setting_info info;
    if (!b->key || !find_setting(b->key, &info) || g_strcmp0(info.group, group) != 0 || g_strcmp0(info.section, section) != 0) {
        b->focus = section_focus(group, section);
        b->focus_first = FALSE;
        send_focus(b);
    }
}

static void on_search(GtkSearchEntry *entry, gpointer data) {
    Browser *b = data;
    if (g_object_get_data(G_OBJECT(entry), "zg-quiet")) return;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
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
    for (size_t g = 0; g < G_N_ELEMENTS(pages); g++) {
        for (size_t i = 0; i < n; i++) {
            zs_setting_info info;
            if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, pages[g].group) != 0) continue;
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
    GtkWidget *scroll = scrolled(child);
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
    if (!find_setting(key, &info)) return;
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

static GtkWidget *make_browser(ZgModel *model, GtkWidget *stack) {
    Browser *b = g_new0(Browser, 1);
    b->model = model;
    b->stack = stack;

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
    g_signal_connect(stack, "notify::visible-child", G_CALLBACK(on_page_changed), b);
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
    GtkWidget *browser = make_browser(model, stack);
    gtk_stack_add_titled(GTK_STACK(stack), browser, "settings", "Settings");
    if (g_object_get_data(G_OBJECT(browser), "zg-open")) gtk_stack_set_visible_child(GTK_STACK(stack), browser);
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
