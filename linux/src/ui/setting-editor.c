/* setting-editor.c: see setting-editor.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "setting-editor.h"

#include <math.h>
#include <string.h>

/* The pause before a value goes to the core, in ms: after typing, and
 * during a drag on a label. */
enum { LIVE_DELAY_MS = 350, SCRUB_DELAY_MS = 60 };

static ZgModel *model_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-model");
}

static const zs_setting_info *info_of(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-info");
}

static const char *key_of(GtkWidget *w) {
    return info_of(w)->name;
}

/* An editor of the inspector: it follows the scope of the model (all
 * layers, or the layers of the selection). */
static gboolean is_scoped(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-scoped") != NULL;
}

/* The part of a part editor (zg_setting_editor_new_for_part), or -1. */
static gint64 part_of(GtkWidget *w) {
    return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "zg-part")) - 1;
}

/* The value that the editor shows: of its part (or the value of the plate
 * while the part has none), or of the scope of the model. Free with
 * g_free. */
static char *editor_get(GtkWidget *w, const char *key) {
    gint64 part = part_of(w);
    if (part >= 0) {
        char *own = zg_model_part_setting(model_of(w), (size_t)part, key);
        return own ? own : zg_model_get(model_of(w), key);
    }
    return zg_model_get_for(model_of(w), key, is_scoped(w));
}

static gboolean editor_set(GtkWidget *w, const char *value, GError **error) {
    gint64 part = part_of(w);
    if (part < 0) return zg_model_set_for(model_of(w), info_of(w)->name, value, is_scoped(w), error);
    if (!zg_model_part_setting_set(model_of(w), (size_t)part, info_of(w)->name, value)) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "not a valid value");
        return FALSE;
    }
    /* The other editors of the setting show the new value. */
    zg_model_announce(model_of(w), info_of(w)->name);
    return TRUE;
}

static gboolean is_number(GtkWidget *w) {
    return info_of(w)->kind == ZS_SETTING_NUMBER || info_of(w)->kind == ZS_SETTING_INTEGER;
}

gboolean zg_parses_as_number(const char *text) {
    char *end = NULL;
    g_ascii_strtod(text, &end);
    return text[0] && end && *end == 0;
}

/* Writes a number with no more digits than it needs, with a dot as the
 * decimal mark in any locale. */
static void format_number(char *buf, size_t cap, double v) {
    g_ascii_formatd(buf, cap, "%.6g", v);
}

/* A line width of 0 means "from the nozzle": the editors show "auto". */
static gboolean is_auto(const char *key) {
    return g_str_has_suffix(key, "line_width");
}

/* A ratio shows as a percentage: the core value 0.5 shows as 50. */
static gboolean is_ratio(const zs_setting_info *info) {
    return (info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER) && strcmp(info->unit, "%") == 0;
}

char *zg_setting_display_value(const zs_setting_info *info, const char *value) {
    if (is_auto(info->name) && zg_parses_as_number(value) && g_ascii_strtod(value, NULL) == 0) return g_strdup("auto");
    if (is_ratio(info) && zg_parses_as_number(value)) {
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

char *zg_setting_value_with_unit(const zs_setting_info *info, const char *value) {
    char *shown = zg_setting_display_value(info, value);
    /* A count of one: "1 layer", not "1 layers". */
    size_t n = strlen(info->unit);
    gboolean one = strcmp(shown, "1") == 0 && n > 1 && info->unit[n - 1] == 's' && info->kind == ZS_SETTING_INTEGER;
    gboolean no_unit = !info->unit[0] || strcmp(shown, "auto") == 0;
    char *text = no_unit ? g_strdup(shown) : g_strdup_printf("%s %.*s", shown, (int)(one ? n - 1 : n), info->unit);
    g_free(shown);
    return text;
}

gboolean zg_setting_find(const char *name, zs_setting_info *out) {
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        if (zs_setting_get_info(i, out) == ZS_OK && strcmp(out->name, name) == 0) return TRUE;
    }
    return FALSE;
}

/* The core value of the text in an editor. Free with g_free. */
static char *to_core(GtkWidget *editor, const char *text) {
    if (is_auto(key_of(editor)) && g_ascii_strcasecmp(text, "auto") == 0) return g_strdup("0");
    if (!is_ratio(info_of(editor)) || !zg_parses_as_number(text)) return g_strdup(text);
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.10g", g_ascii_strtod(text, NULL) / 100);
    return g_strdup(buf);
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
    if (!is_number(editor) || !(info->slider_max > info->slider_min)) return;
    char *value = editor_get(editor, key_of(editor));
    gboolean unusual = zg_parses_as_number(value) &&
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
    if (is_number(editor) && info->limit_max > info->limit_min && zg_parses_as_number(value)) {
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
    char *old = editor_get(editor, key_of(editor));
    gboolean same = g_strcmp0(old, value) == 0;
    if (!same && is_number(editor) && zg_parses_as_number(old) && zg_parses_as_number(value)) {
        same = g_ascii_strtod(old, NULL) == g_ascii_strtod(value, NULL);
    }
    g_free(old);
    gboolean ok = TRUE;
    if (same) {
        gtk_widget_remove_css_class(editor, "error");
    } else if (editor_set(editor, value, &error)) {
        gtk_widget_remove_css_class(editor, "error");
        gtk_widget_set_tooltip_text(editor, info->doc);
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
    if (zg_parses_as_number(text) && text[strlen(text) - 1] != '.') commit_value(entry, text, TRUE);
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
    gboolean integer = info_of(entry)->kind == ZS_SETTING_INTEGER;
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
    if (!zg_parses_as_number(text)) return FALSE;
    double steps = (key == GDK_KEY_Up || key == GDK_KEY_Page_Up) ? 1 : -1;
    if ((mods & GDK_SHIFT_MASK) || key == GDK_KEY_Page_Up || key == GDK_KEY_Page_Down) steps *= 10;
    char *base = g_strdup(text);
    step_value(entry, base, steps, (mods & GDK_CONTROL_MASK) != 0, 150);
    g_free(base);
    return TRUE;
}

static void on_scrub_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    GtkWidget *entry = data;
    g_object_set_data_full(G_OBJECT(entry), "zg-scrub-base", g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry))), g_free);
}

static void on_scrub_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    GtkWidget *entry = data;
    const char *base = g_object_get_data(G_OBJECT(entry), "zg-scrub-base");
    if (!base || !zg_parses_as_number(base)) return;
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

void zg_setting_editor_add_scrub(GtkWidget *entry, GtkWidget *label) {
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
static void on_slider(GtkRange *range, gpointer data);

/* The last value of a throttled slider goes to the core at the end of the
 * wait. */
static gboolean on_slider_wait(gpointer data) {
    GtkRange *range = data;
    g_object_set_data(G_OBJECT(range), "zg-wait", NULL);
    g_object_set_data(G_OBJECT(range), "zg-last", GSIZE_TO_POINTER((gsize)(g_get_monotonic_time() / 1000)));
    GtkWidget *entry = g_object_get_data(G_OBJECT(range), "zg-entry");
    commit_value(entry, gtk_editable_get_text(GTK_EDITABLE(entry)), TRUE);
    return G_SOURCE_REMOVE;
}

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
    guint ms = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(range), "zg-throttle"));
    /* The same value as before: no new slice. */
    if (!ms && strcmp(buf, gtk_editable_get_text(GTK_EDITABLE(entry))) == 0) return;
    set_entry_text(entry, buf);
    cancel_live(entry);
    /* A throttled slider sends a value at most each `ms`: each value
     * starts a slice. The last value goes at the end of the wait. */
    if (ms) {
        if (g_object_get_data(G_OBJECT(range), "zg-wait")) return;
        gint64 now = g_get_monotonic_time() / 1000;
        gint64 last = (gint64)GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(range), "zg-last"));
        if (last && now - last < (gint64)ms) {
            guint id = g_timeout_add((guint)(ms - (now - last)), on_slider_wait, range);
            g_object_set_data(G_OBJECT(range), "zg-wait", GUINT_TO_POINTER(id));
            return;
        }
        g_object_set_data(G_OBJECT(range), "zg-last", GSIZE_TO_POINTER((gsize)now));
    }
    /* No wait: the model queues the value while a slice runs. */
    commit_value(entry, buf, TRUE);
}

/* Moves the slider to the value of the entry, after a change from an other
 * place. */
static void sync_slider(GtkWidget *entry) {
    GtkWidget *slider = g_object_get_data(G_OBJECT(entry), "zg-slider");
    if (!slider) return;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!zg_parses_as_number(text)) return;
    g_object_set_data(G_OBJECT(slider), "zg-setting", GINT_TO_POINTER(1));
    gtk_range_set_value(GTK_RANGE(slider), g_ascii_strtod(text, NULL));
    g_object_set_data(G_OBJECT(slider), "zg-setting", NULL);
}

static void on_slider_destroy(GtkWidget *slider, gpointer data) {
    guint id = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(slider), "zg-wait"));
    if (id) g_source_remove(id);
    g_object_set_data(G_OBJECT(slider), "zg-wait", NULL);
}

void zg_setting_editor_slider_throttle(GtkWidget *slider, guint ms) {
    g_object_set_data(G_OBJECT(slider), "zg-throttle", GUINT_TO_POINTER(ms));
    g_signal_connect(slider, "destroy", G_CALLBACK(on_slider_destroy), NULL);
}

GtkWidget *zg_setting_editor_slider_new(GtkWidget *entry) {
    const zs_setting_info *info = info_of(entry);
    double scale = strcmp(info->unit, "%") == 0 ? 100 : 1;
    double lo = info->slider_min * scale, hi = info->slider_max * scale;
    double step = info->kind == ZS_SETTING_INTEGER ? 1 : info->slider_step * scale;
    if (!(step > 0)) step = pow(10, floor(log10((hi - lo) / 100)));
    GtkWidget *slider = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step);
    gtk_scale_set_draw_value(GTK_SCALE(slider), FALSE);
    /* A tick at the default value. */
    if (zg_parses_as_number(info->default_value)) {
        double d = g_ascii_strtod(info->default_value, NULL) * scale;
        if (d >= lo && d <= hi) gtk_scale_add_mark(GTK_SCALE(slider), d, GTK_POS_BOTTOM, NULL);
    }
    gtk_widget_set_hexpand(slider, TRUE);
    gtk_widget_add_css_class(slider, "zg-slider");
    gtk_widget_set_tooltip_text(slider, info->doc);
    g_object_set_data(G_OBJECT(entry), "zg-slider", slider);
    /* The slider is a part of the editor of its setting (for the history:
     * a drag and the typing in the entry are one edit). */
    g_object_set_data(G_OBJECT(slider), "zg-info", (gpointer)info);
    sync_slider(entry);
    g_object_set_data(G_OBJECT(slider), "zg-entry", entry);
    g_signal_connect(slider, "value-changed", G_CALLBACK(on_slider), entry);
    return slider;
}

/* ---- the editors ---- */

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

/* A speed ratio: the unit label also gives the speed that it makes, for
 * example "% = 45 mm/s". */
/* A thickness that the slicer covers with whole layers. */
static gboolean is_layer_thickness(const char *key) {
    return strcmp(key, "project.top_thickness") == 0 || strcmp(key, "project.bottom_thickness") == 0;
}

static void show_ratio_speed(GtkWidget *editor, const char *value) {
    GtkWidget *unit = g_object_get_data(G_OBJECT(editor), "zg-unit-label");
    if (!unit) return;
    if (is_layer_thickness(key_of(editor))) {
        /* The layers that cover the thickness (rounded up, as the slicer
         * counts them), at the layer height of the scope. */
        char *lh = editor_get(editor, "project.layer_height");
        double h = g_ascii_strtod(lh, NULL), t = g_ascii_strtod(value, NULL);
        g_free(lh);
        if (h <= 0) return;
        long n = t <= 0 ? 0 : (long)ceil(t / h - 1e-6);
        gboolean exact = fabs(n * h - t) < 1e-6;
        char *text = g_strdup_printf(exact ? "mm = %ld layer%s" : "mm \u2192 %ld layer%s", n, n == 1 ? "" : "s");
        gtk_label_set_text(GTK_LABEL(unit), text);
        g_free(text);
        char *tip = exact ? g_strdup_printf("%ld layers of %.2f mm.", n, h)
                          : g_strdup_printf("Not a multiple of the layer height (%.2f mm): it prints %ld layers, %.2f mm.", h, n, n * h);
        gtk_widget_set_tooltip_text(unit, tip);
        g_free(tip);
        return;
    }
    double mm_s = 0;
    if (zs_app_ratio_speed(zg_model_core(model_of(editor)), key_of(editor), value, &mm_s) != ZS_OK) return;
    char *text = g_strdup_printf("%% = %.0f mm/s", mm_s);
    gtk_label_set_text(GTK_LABEL(unit), text);
    g_free(text);
}

/* Other settings (the machine speed, the flow limit, the line width) change
 * the speed of a ratio too. */
static void on_any_setting(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *editor = data;
    char *value = editor_get(editor, key_of(editor));
    show_ratio_speed(editor, value);
    g_free(value);
}

/* Shows the value of the core in an editor, after a set from an other
 * editor of the same setting. An editor with the focus keeps its text. */
void zg_setting_editor_refresh(GtkWidget *editor) {
    char *value = editor_get(editor, key_of(editor));
    show_ratio_speed(editor, value);
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
        char *shown = zg_setting_display_value(info_of(editor), value);
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
    if (g_strcmp0(key, key_of(editor)) == 0) zg_setting_editor_refresh(editor);
}

static void tag(GtkWidget *editor, ZgModel *model, const zs_setting_info *info) {
    g_object_set_data(G_OBJECT(editor), "zg-model", model);
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

static GtkWidget *editor_build(ZgModel *model, const zs_setting_info *info, gboolean scoped, gint64 part) {
    char *value = NULL;
    if (part >= 0) value = zg_model_part_setting(model, (size_t)part, info->name);
    if (!value) value = part >= 0 ? zg_model_get(model, info->name) : zg_model_get_for(model, info->name, scoped);
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
        char *shown = zg_setting_display_value(info, value);
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
    if (scoped) g_object_set_data(G_OBJECT(editor), "zg-scoped", GINT_TO_POINTER(1));
    if (part >= 0) g_object_set_data(G_OBJECT(editor), "zg-part", GINT_TO_POINTER((int)part + 1));
    gtk_widget_set_valign(editor, GTK_ALIGN_CENTER);
    show_unusual(editor);
    g_free(value);
    return editor;
}

GtkWidget *zg_setting_editor_new(ZgModel *model, const zs_setting_info *info, gboolean scoped) {
    return editor_build(model, info, scoped, -1);
}

GtkWidget *zg_setting_editor_new_for_part(ZgModel *model, const zs_setting_info *info, size_t part) {
    return editor_build(model, info, FALSE, (gint64)part);
}

ZgModel *zg_setting_editor_model(GtkWidget *editor) {
    return model_of(editor);
}

const zs_setting_info *zg_setting_editor_info(GtkWidget *editor) {
    return info_of(editor);
}

void zg_setting_editor_show_speed(GtkWidget *editor, GtkWidget *unit) {
    ZgModel *model = model_of(editor);
    double probe;
    if (!is_layer_thickness(key_of(editor)) && zs_app_ratio_speed(zg_model_core(model), key_of(editor), "1", &probe) != ZS_OK) return;
    g_object_set_data(G_OBJECT(editor), "zg-unit-label", unit);
    g_signal_connect_object(model, "setting-changed", G_CALLBACK(on_any_setting), editor, 0);
    char *value = editor_get(editor, key_of(editor));
    show_ratio_speed(editor, value);
    g_free(value);
}
