/* search.c: see search.h.
 *
 * The score of a setting for a query: each word of the query must match
 * the label, the name, the section, or the help of the setting, by itself
 * or by a word of the same meaning (SAME, also the names of other
 * slicers). A match at the start of the label scores most. The settings of
 * the part come first, then the filament, then the printer.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "search.h"

#include <math.h>
#include <string.h>

#include "../prefs/printers.h"
#include "float.h"
#include "setting-editor.h"

enum { MAX_SETTINGS = 14, MAX_ACTIONS = 4, DRAG_MS = 90 };

/* The first place of the box: at the left of the view, under the
 * toolbar, right of the tool strip. */
static const double PLACE_X = 64, PLACE_Y = 62;

/* Words with the same meaning in a search: the names of zslice, and the
 * names of other slicers (Cura, PrusaSlicer). A word of the query also
 * finds the other words of its groups, with a lower score. The same
 * groups as web/app/search.js. */
static const char *const SAME[][13] = {
    {"speed", "speeds", "motion", "velocity", "fast", "slow", "mm/s", "feedrate", "accel", "acceleration", "jerk", "max speed", NULL},
    {"acceleration", "accel", "jerk", "motion", NULL},
    {"temperature", "temp", "heat", "hot", "nozzle temp", "bed temp", "temperatures", NULL},
    {"fan", "cooling", "cool", "fans", NULL},
    {"wall", "walls", "perimeter", "perimeters", "shell", "shells", "outline", NULL},
    {"infill", "fill", "density", "sparse", NULL},
    {"skin", "top", "bottom", "solid", "top and bottom", NULL},
    {"support", "supports", "overhang", "overhangs", "tree", NULL},
    {"brim", "skirt", "adhesion", "raft", NULL},
    {"retraction", "retract", "stringing", "z hop", "wipe", NULL},
    {"travel", "moves", "combing", "avoid", NULL},
    {"layer", "layers", "height", "layer height", "resolution", NULL},
    {"first layer", "initial", "first", "bed adhesion", NULL},
    {"flow", "extrusion", "multiplier", "extrusion multiplier", "volumetric", NULL},
    {"seam", "z seam", "scarf", NULL},
    {"bridge", "bridges", "bridging", NULL},
    {"ironing", "iron", "smooth", NULL},
    {"shrink", "shrinkage", "compensation", "xy offset", "horizontal expansion", "elephant foot", NULL},
    {"gcode", "g-code", "start", "end", "macro", NULL},
    {"bed", "plate", "build plate", "bed size", NULL},
    {"line width", "extrusion width", "width", NULL},
};

/* The actions in the results: the label, the keys, a hint, and the
 * action with its target (a string, or NULL). */
typedef struct {
    const char *label, *keys, *hint, *action, *target;
} Action;

static const Action ACTIONS[] = {
    {"Open a model…", "Ctrl+O", "add models to the plate", "app.open", NULL},
    {"Export G-code…", "Ctrl+E", NULL, "win.export", NULL},
    {"Print", NULL, "send the G-code to the printer and start", "win.send-print", NULL},
    {"Upload to the printer", NULL, "send the G-code, and do not start", "win.send-only", NULL},
    {"Arrange the plate", NULL, "pack the parts on the bed", "win.arrange", NULL},
    {"Smart placement", NULL, "turn and arrange the parts", "win.smart-place", NULL},
    {"Check the print", NULL, "problems and advice", "preview.check", NULL},
    {"Save the plate as 3MF…", "Ctrl+S", "the parts and their settings", "win.save-plate", NULL},
    {"Undo", "Ctrl+Z", NULL, "win.undo", NULL},
    {"Redo", "Ctrl+Shift+Z", NULL, "win.redo", NULL},
    {"2D layer view", NULL, NULL, "preview.view", "2d"},
    {"3D view", NULL, NULL, "preview.view", "3d"},
    {"Manage printers…", "Ctrl+,", "preferences, connections, API keys", "win.preferences", NULL},
    {"Compare with Cura…", NULL, NULL, "win.compare-cura", NULL},
    {"Open a project", NULL, "printdeck.yml from GitHub or a folder", "win.show-page", "project"},
    {"History", NULL, "the changes, undo one change", "win.show-page", "history"},
    {"Keyboard shortcuts", "?", NULL, "win.shortcuts", NULL},
    {"All settings", "N", "the panel of the settings, the selected line, the history, and the project", "win.show-page", "settings"},
};

/* A result: a setting with its controls, or an action. */
typedef struct {
    GtkWidget *row;
    zs_setting_info info; /* a setting (info.name != NULL) */
    GtkWidget *editor, *slider, *eye, *tag;
    const Action *action;
} Row;

typedef struct {
    ZgModel *model;
    GtkWidget *card, *head, *scope_label, *entry, *list, *scroll;
    GPtrArray *rows; /* Row * */
    guint index;
    gint64 part; /* the part of the search, or -1 */
    char *eye_on; /* the setting whose eye is on, or NULL */
    gboolean filling;
} Search;

static Search *get(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-search");
}

/* ---- the score ---- */

static gboolean starts_word(const char *text, const char *w) {
    size_t n = strlen(w);
    for (const char *p = text; *p;) {
        if (strncmp(p, w, n) == 0) return TRUE;
        p = strchr(p, ' ');
        if (!p) break;
        p++;
    }
    return FALSE;
}

/* The score of one word (or a phrase) in a setting: 0 for no match. The
 * texts are in lower case. */
static double word_score(const char *label, const char *name, const char *section, const char *doc, const char *w) {
    if (g_str_has_prefix(label, w)) return 40;
    if (starts_word(label, w)) return 30;
    if (strstr(label, w)) return 20;
    char *under = g_strdelimit(g_strdup(w), " ", '_');
    gboolean in_name = strstr(name, under) != NULL;
    g_free(under);
    if (in_name) return 14;
    if (strstr(section, w)) return 12;
    if (strstr(doc, w)) return 3;
    return 0;
}

static double score(const zs_setting_info *info, char **words) {
    char *label = g_utf8_strdown(info->label, -1);
    char *name = g_utf8_strdown(info->name, -1);
    char *section = g_utf8_strdown(info->section, -1);
    char *doc = g_utf8_strdown(info->doc, -1);
    double total = 0;
    for (int i = 0; words[i]; i++) {
        const char *w = words[i];
        double best = word_score(label, name, section, doc, w);
        /* The words of its groups: a group counts when one of its words
         * starts with w. */
        if (strlen(w) >= 3) {
            for (size_t g = 0; g < G_N_ELEMENTS(SAME); g++) {
                gboolean in = FALSE;
                for (int k = 0; SAME[g][k] && !in; k++) in = g_str_has_prefix(SAME[g][k], w);
                if (!in) continue;
                for (int k = 0; SAME[g][k]; k++) best = MAX(best, 0.75 * word_score(label, name, section, doc, SAME[g][k]));
            }
        }
        if (best == 0) {
            total = 0;
            break;
        }
        total += best;
    }
    if (total > 0) {
        if (strcmp(info->group, "project") == 0) total += 2;
        if (strcmp(info->group, "engine") == 0) total -= 2;
    }
    g_free(label);
    g_free(name);
    g_free(section);
    g_free(doc);
    return total;
}

/* ---- the rows ---- */

static void select_row(Search *s, guint i, gboolean focus) {
    if (s->rows->len == 0) return;
    s->index = MIN(i, s->rows->len - 1);
    for (guint k = 0; k < s->rows->len; k++) {
        Row *r = g_ptr_array_index(s->rows, k);
        if (k == s->index) gtk_widget_add_css_class(r->row, "zg-sr-on");
        else gtk_widget_remove_css_class(r->row, "zg-sr-on");
    }
    Row *r = g_ptr_array_index(s->rows, s->index);
    if (focus) gtk_widget_grab_focus(r->row);
    /* The row shows in the list. */
    graphene_rect_t b;
    GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(s->scroll));
    if (gtk_widget_compute_bounds(r->row, s->list, &b)) {
        double top = gtk_adjustment_get_value(adj), page = gtk_adjustment_get_page_size(adj);
        if (b.origin.y < top) gtk_adjustment_set_value(adj, b.origin.y);
        else if (b.origin.y + b.size.height > top + page) gtk_adjustment_set_value(adj, b.origin.y + b.size.height - page);
    }
}

/* The setting whose lines the view shows alone, or NULL. */
static void set_eye(Search *s, const char *name) {
    g_free(s->eye_on);
    s->eye_on = name ? g_strdup(name) : NULL;
    for (guint k = 0; k < s->rows->len; k++) {
        Row *r = g_ptr_array_index(s->rows, k);
        if (!r->eye) continue;
        gboolean on = name && strcmp(r->info.name, name) == 0;
        g_object_set_data(G_OBJECT(r->eye), "zg-quiet", GINT_TO_POINTER(1));
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(r->eye), on);
        g_object_set_data(G_OBJECT(r->eye), "zg-quiet", NULL);
    }
    if (!name) {
        zg_model_set_focus(s->model, 0, FALSE);
        gtk_widget_activate_action(s->card, "win.refocus", NULL);
        return;
    }
    zs_setting_effect e = {0};
    zs_setting_get_effect(name, &e);
    zg_model_set_focus(s->model, e.features ? e.features : (1u << ZS_FEATURE_COUNT) - 1, e.first_layer_only);
}

static void on_eye(GtkToggleButton *b, gpointer data) {
    Search *s = data;
    if (g_object_get_data(G_OBJECT(b), "zg-quiet")) return;
    Row *r = g_object_get_data(G_OBJECT(b), "zg-row");
    gboolean on = gtk_toggle_button_get_active(b);
    set_eye(s, on ? r->info.name : NULL);
}

static const char *group_title(const char *group) {
    if (strcmp(group, "project") == 0) return "Part";
    if (strcmp(group, "filament") == 0) return "Filament";
    if (strcmp(group, "machine") == 0) return "Printer";
    return "Engine";
}

/* The tag under a setting: its group, its section, and where its value
 * comes from. */
static void fill_tag(Search *s, Row *r) {
    char *source = zg_model_source_text(s->model, r->info.name, s->part, NULL);
    char *text = g_strdup_printf("%s · %s%s%s", group_title(r->info.group), r->info.section, source ? " · " : "", source ? source : "");
    gtk_label_set_text(GTK_LABEL(r->tag), text);
    g_free(text);
    g_free(source);
}

static void on_setting_changed(ZgModel *model, const char *key, gpointer data) {
    Search *s = data;
    if (!gtk_widget_get_visible(s->card)) return;
    for (guint k = 0; k < s->rows->len; k++) {
        Row *r = g_ptr_array_index(s->rows, k);
        if (r->info.name && g_strcmp0(key, r->info.name) == 0) fill_tag(s, r);
    }
}

/* Left and Right: one step of a number, or the next choice. */
static void nudge(Search *s, Row *r, int dir) {
    if (!r->info.name || !r->editor) return;
    const zs_setting_info *info = &r->info;
    if (GTK_IS_SWITCH(r->editor)) {
        gtk_switch_set_active(GTK_SWITCH(r->editor), !gtk_switch_get_active(GTK_SWITCH(r->editor)));
    } else if (GTK_IS_DROP_DOWN(r->editor)) {
        guint n = g_list_model_get_n_items(gtk_drop_down_get_model(GTK_DROP_DOWN(r->editor)));
        guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(r->editor));
        if (n > 0) gtk_drop_down_set_selected(GTK_DROP_DOWN(r->editor), (i + n + (guint)dir) % n);
    } else if (GTK_IS_EDITABLE(r->editor) && (info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER)) {
        char *value = NULL;
        if (s->part >= 0) value = zg_model_part_setting(s->model, (size_t)s->part, info->name);
        if (!value) value = zg_model_get(s->model, info->name);
        gboolean ratio = strcmp(info->unit, "%") == 0;
        double step = info->slider_step > 0 ? info->slider_step : info->kind == ZS_SETTING_INTEGER ? 1 : ratio ? 0.01 : 0.1;
        double v = g_ascii_strtod(value, NULL) + dir * step;
        g_free(value);
        char core[G_ASCII_DTOSTR_BUF_SIZE];
        g_ascii_formatd(core, sizeof core, "%.10g", v);
        char *shown = zg_setting_display_value(info, core);
        gtk_editable_set_text(GTK_EDITABLE(r->editor), shown);
        g_free(shown);
        /* Enter in the entry sends it. */
        gtk_widget_activate(r->editor);
    }
}

static void activate_row(Search *s, Row *r) {
    if (r->action) {
        const Action *a = r->action;
        GtkWidget *card = s->card;
        zg_search_close(card);
        gtk_widget_activate_action_variant(card, a->action, a->target ? g_variant_new_string(a->target) : NULL);
        return;
    }
    if (GTK_IS_SWITCH(r->editor)) nudge(s, r, 1);
    else if (r->editor) gtk_widget_grab_focus(r->editor);
}

static void on_row_enter(GtkEventControllerMotion *m, double x, double y, gpointer data) {
    Search *s = data;
    GtkWidget *row = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(m));
    for (guint k = 0; k < s->rows->len; k++) {
        if (((Row *)g_ptr_array_index(s->rows, k))->row == row) {
            select_row(s, k, FALSE);
            return;
        }
    }
}

static void on_action_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Search *s = data;
    Row *r = g_object_get_data(G_OBJECT(gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g))), "zg-row");
    if (r) activate_row(s, r);
}

static Row *row_new(Search *s, GtkWidget *widget) {
    Row *r = g_new0(Row, 1);
    r->row = widget;
    gtk_widget_set_focusable(widget, TRUE);
    gtk_widget_add_css_class(widget, "zg-sr");
    g_object_set_data(G_OBJECT(widget), "zg-row", r);
    GtkEventController *m = gtk_event_controller_motion_new();
    g_signal_connect(m, "enter", G_CALLBACK(on_row_enter), s);
    gtk_widget_add_controller(widget, m);
    g_ptr_array_add(s->rows, r);
    return r;
}

/* Marks a control of a result: the keys of the list leave it alone. */
static void mark_control(GtkWidget *w) {
    g_object_set_data(G_OBJECT(w), "zg-sr-control", GINT_TO_POINTER(1));
}

static GtkWidget *setting_row(Search *s, const zs_setting_info *info) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    Row *r = row_new(s, row);
    r->info = *info;
    GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(labels, TRUE);
    GtkWidget *label = gtk_label_new(info->label);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_widget_set_tooltip_text(label, info->doc);
    r->tag = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(r->tag), 0);
    gtk_label_set_ellipsize(GTK_LABEL(r->tag), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(r->tag, "zg-sr-tag");
    gtk_box_append(GTK_BOX(labels), label);
    gtk_box_append(GTK_BOX(labels), r->tag);
    fill_tag(s, r);
    gtk_box_append(GTK_BOX(row), labels);
    /* The eye: the view shows only the lines that this setting changes,
     * until a click on it again. */
    r->eye = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(r->eye), "view-reveal-symbolic");
    gtk_widget_add_css_class(r->eye, "flat");
    gtk_widget_add_css_class(r->eye, "zg-sr-eye");
    gtk_widget_set_valign(r->eye, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(r->eye, "Show only the lines that this setting changes, the others as ghosts (V)");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(r->eye), s->eye_on && strcmp(s->eye_on, info->name) == 0);
    g_object_set_data(G_OBJECT(r->eye), "zg-row", r);
    g_signal_connect(r->eye, "toggled", G_CALLBACK(on_eye), s);
    gtk_box_append(GTK_BOX(row), r->eye);
    /* The controls: a slider for a number with a usual range, the editor,
     * and the unit. */
    GtkWidget *controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_valign(controls, GTK_ALIGN_CENTER);
    r->editor = s->part >= 0 ? zg_setting_editor_new_for_part(s->model, info, (size_t)s->part)
                             : zg_setting_editor_new(s->model, info, FALSE);
    gboolean number = info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER;
    if (number && info->slider_max > info->slider_min) {
        r->slider = zg_setting_editor_slider_new(r->editor);
        zg_setting_editor_slider_throttle(r->slider, DRAG_MS);
        gtk_widget_set_size_request(r->slider, 130, -1);
        gtk_widget_set_hexpand(r->slider, FALSE);
        gtk_widget_add_css_class(r->slider, "zg-sr-slider");
        mark_control(r->slider);
        gtk_box_append(GTK_BOX(controls), r->slider);
    }
    if (GTK_IS_TEXT_VIEW(r->editor)) {
        GtkWidget *sc = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sc), r->editor);
        gtk_widget_set_size_request(sc, 220, 70);
        gtk_box_append(GTK_BOX(controls), sc);
    } else {
        gtk_box_append(GTK_BOX(controls), r->editor);
    }
    if (!GTK_IS_SWITCH(r->editor)) mark_control(r->editor);
    if (info->unit[0] && number) {
        GtkWidget *unit = gtk_label_new(info->unit);
        gtk_widget_add_css_class(unit, "dim-label");
        gtk_widget_add_css_class(unit, "zg-unit");
        gtk_label_set_xalign(GTK_LABEL(unit), 0);
        gtk_box_append(GTK_BOX(controls), unit);
    }
    gtk_box_append(GTK_BOX(row), controls);
    return row;
}

static GtkWidget *action_row(Search *s, const Action *a) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    Row *r = row_new(s, row);
    r->action = a;
    gtk_widget_add_css_class(row, "zg-sr-action");
    GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(labels, TRUE);
    GtkWidget *label = gtk_label_new(a->label);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_box_append(GTK_BOX(labels), label);
    if (a->hint) {
        GtkWidget *hint = gtk_label_new(a->hint);
        gtk_label_set_xalign(GTK_LABEL(hint), 0);
        gtk_label_set_ellipsize(GTK_LABEL(hint), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(hint, "zg-sr-tag");
        gtk_box_append(GTK_BOX(labels), hint);
    }
    gtk_box_append(GTK_BOX(row), labels);
    if (a->keys) {
        GtkWidget *keys = gtk_label_new(a->keys);
        gtk_widget_add_css_class(keys, "zg-keycap");
        gtk_widget_set_valign(keys, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(row), keys);
    }
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "released", G_CALLBACK(on_action_click), s);
    gtk_widget_add_controller(row, GTK_EVENT_CONTROLLER(click));
    return row;
}

static GtkWidget *note(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_widget_add_css_class(l, css);
    return l;
}

typedef struct {
    zs_setting_info info;
    double score;
} Match;

static int by_score(gconstpointer a, gconstpointer b) {
    double d = ((const Match *)b)->score - ((const Match *)a)->score;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

static gboolean action_matches(const Action *a, char **words) {
    char *label = g_utf8_strdown(a->label, -1);
    char *hint = g_utf8_strdown(a->hint ? a->hint : "", -1);
    gboolean ok = TRUE;
    for (int i = 0; words[i] && ok; i++) ok = strstr(label, words[i]) || strstr(hint, words[i]);
    g_free(label);
    g_free(hint);
    return ok;
}

static void fill(Search *s) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(s->list))) gtk_box_remove(GTK_BOX(s->list), child);
    g_ptr_array_set_size(s->rows, 0);
    s->index = 0;
    char *q = g_utf8_strdown(gtk_editable_get_text(GTK_EDITABLE(s->entry)), -1);
    char **words = g_strsplit_set(g_strstrip(q), " \t", -1);
    /* No empty words. */
    int n = 0;
    for (int i = 0; words[i]; i++) {
        if (words[i][0]) words[n++] = words[i];
        else g_free(words[i]);
    }
    words[n] = NULL;
    if (n == 0) {
        gtk_box_append(GTK_BOX(s->list), note(s->part >= 0 ? "Type a setting that this part can have of its own (infill, walls, speed)."
                                                            : "Type a setting (infill, walls, brim, speed) or an action (export, arrange, print).",
                                              "zg-sr-note"));
        g_strfreev(words);
        g_free(q);
        return;
    }
    GArray *matches = g_array_new(FALSE, FALSE, sizeof(Match));
    for (size_t i = 0; i < zs_setting_count(); i++) {
        Match m;
        if (zs_setting_get_info(i, &m.info) != ZS_OK) continue;
        if (s->part >= 0 && !m.info.per_part) continue;
        m.score = score(&m.info, words);
        if (m.score > 0) g_array_append_val(matches, m);
    }
    g_array_sort(matches, by_score);
    guint shown = MIN(matches->len, MAX_SETTINGS);
    if (shown > 0) {
        gtk_box_append(GTK_BOX(s->list), note("Settings", "zg-sr-group"));
        for (guint i = 0; i < shown; i++) gtk_box_append(GTK_BOX(s->list), setting_row(s, &g_array_index(matches, Match, i).info));
        if (matches->len > shown) {
            char *more = g_strdup_printf("%u more settings match. Type more words to narrow the list.", matches->len - shown);
            gtk_box_append(GTK_BOX(s->list), note(more, "zg-sr-note"));
            g_free(more);
        }
    }
    int actions = 0;
    for (size_t i = 0; s->part < 0 && i < G_N_ELEMENTS(ACTIONS) && actions < MAX_ACTIONS; i++) {
        if (!action_matches(&ACTIONS[i], words)) continue;
        if (actions++ == 0) gtk_box_append(GTK_BOX(s->list), note("Actions", "zg-sr-group"));
        gtk_box_append(GTK_BOX(s->list), action_row(s, &ACTIONS[i]));
    }
    if (s->rows->len == 0) gtk_box_append(GTK_BOX(s->list), note("No setting or action matches.", "zg-sr-note"));
    g_array_free(matches, TRUE);
    g_strfreev(words);
    g_free(q);
    select_row(s, 0, FALSE);
}

static void on_changed(GtkEditable *e, gpointer data) {
    Search *s = data;
    if (!s->filling) fill(s);
}

/* ---- the keys ---- */

static gboolean in_control(Search *s, GtkWidget *focus) {
    for (GtkWidget *w = focus; w && w != s->card; w = gtk_widget_get_parent(w)) {
        if (w == s->entry) return FALSE;
        if (g_object_get_data(G_OBJECT(w), "zg-sr-control")) return TRUE;
    }
    /* A list of a drop-down is a popover of its own. */
    return focus && gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER) != NULL;
}

static gboolean in_entry(Search *s, GtkWidget *focus) {
    return focus && (focus == s->entry || gtk_widget_is_ancestor(focus, s->entry));
}

static gboolean on_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Search *s = data;
    if (mods & (GDK_CONTROL_MASK | GDK_ALT_MASK)) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(s->card));
    gboolean control = in_control(s, focus), entry = in_entry(s, focus);
    Row *r = s->rows->len ? g_ptr_array_index(s->rows, s->index) : NULL;
    switch (key) {
    case GDK_KEY_Escape:
        if (control) select_row(s, s->index, TRUE);
        else zg_search_close(s->card);
        return TRUE;
    case GDK_KEY_Down:
    case GDK_KEY_Up:
        if (control) return FALSE;
        if (entry) {
            if (key == GDK_KEY_Down) select_row(s, s->index, TRUE);
            return TRUE;
        }
        if (key == GDK_KEY_Up && s->index == 0) {
            gtk_widget_grab_focus(s->entry);
            return TRUE;
        }
        select_row(s, key == GDK_KEY_Down ? s->index + 1 : (s->index > 0 ? s->index - 1 : 0), TRUE);
        return TRUE;
    case GDK_KEY_Left:
    case GDK_KEY_Right:
        if (control || entry || !r) return FALSE;
        nudge(s, r, key == GDK_KEY_Right ? 1 : -1);
        return TRUE;
    case GDK_KEY_v:
    case GDK_KEY_V:
        if (control || entry || !r || !r->eye) return FALSE;
        set_eye(s, s->eye_on && strcmp(s->eye_on, r->info.name) == 0 ? NULL : r->info.name);
        return TRUE;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
    case GDK_KEY_space:
        if (control || !r) return FALSE;
        if (entry && key == GDK_KEY_space) return FALSE;
        /* A button that has the focus (the eye, a close) takes its key. */
        if (!entry && focus && GTK_IS_BUTTON(focus)) return FALSE;
        activate_row(s, r);
        return TRUE;
    case GDK_KEY_slash:
        /* / again closes the search (it stays open while the view moves). */
        if (entry || control) return FALSE;
        zg_search_close(s->card);
        return TRUE;
    default: return FALSE;
    }
}

/* ---- the place ---- */

static void on_moved(GtkWidget *card, double x, double y, gpointer data) {
    char buf[64];
    g_snprintf(buf, sizeof buf, "%.0f,%.0f", x, y);
    zg_pref_set("search_place", buf);
}

/* A double click on the head: back to the first place. */
static void on_head_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Search *s = data;
    if (n != 2) return;
    zg_pref_set("search_place", "");
    zg_float_place(s->card, PLACE_X, PLACE_Y);
    zg_float_forget(s->card);
}

static void place_saved(Search *s) {
    char *saved = zg_pref_get("search_place", "");
    double x = PLACE_X, y = PLACE_Y;
    char **xy = g_strsplit(saved, ",", 2);
    if (xy[0] && xy[1]) {
        x = g_ascii_strtod(xy[0], NULL);
        y = g_ascii_strtod(xy[1], NULL);
    }
    g_strfreev(xy);
    g_free(saved);
    zg_float_place(s->card, x, y);
}

static void on_close_clicked(GtkButton *b, gpointer data) {
    zg_search_close(((Search *)data)->card);
}

static void search_free(gpointer data) {
    Search *s = data;
    g_signal_handlers_disconnect_by_data(s->model, s);
    g_ptr_array_free(s->rows, TRUE);
    g_free(s->eye_on);
    g_object_unref(s->model);
    g_free(s);
}

GtkWidget *zg_search_new(ZgModel *model) {
    Search *s = g_new0(Search, 1);
    s->model = g_object_ref(model);
    s->rows = g_ptr_array_new_with_free_func(g_free);
    s->part = -1;
    s->card = zg_card_new();
    gtk_widget_add_css_class(s->card, "zg-search");
    gtk_widget_set_size_request(s->card, 500, -1);
    /* The head: a grip, the scope (a part), the entry, and ×. */
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(head, "zg-card-head");
    GtkWidget *grip = gtk_image_new_from_icon_name("system-search-symbolic");
    gtk_widget_set_tooltip_text(grip, "Drag to move the search. Double-click: back to its first place.");
    gtk_box_append(GTK_BOX(head), grip);
    s->scope_label = gtk_label_new("");
    gtk_widget_add_css_class(s->scope_label, "zg-sr-scope");
    gtk_widget_set_visible(s->scope_label, FALSE);
    gtk_box_append(GTK_BOX(head), s->scope_label);
    s->entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(s->entry), "Search settings and actions");
    gtk_widget_set_hexpand(s->entry, TRUE);
    g_signal_connect(s->entry, "changed", G_CALLBACK(on_changed), s);
    gtk_box_append(GTK_BOX(head), s->entry);
    GtkWidget *close = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_add_css_class(close, "flat");
    gtk_widget_add_css_class(close, "circular");
    gtk_widget_set_tooltip_text(close, "Close the search (Esc)");
    g_signal_connect(close, "clicked", G_CALLBACK(on_close_clicked), s);
    gtk_box_append(GTK_BOX(head), close);
    gtk_box_append(GTK_BOX(s->card), head);
    s->head = head;
    zg_float_movable(s->card, head, on_moved, s);
    GtkGesture *dbl = gtk_gesture_click_new();
    g_signal_connect(dbl, "pressed", G_CALLBACK(on_head_click), s);
    gtk_widget_add_controller(head, GTK_EVENT_CONTROLLER(dbl));
    /* The results. */
    s->list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    s->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(s->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(s->scroll), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(s->scroll), 520);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s->scroll), s->list);
    gtk_box_append(GTK_BOX(s->card), s->scroll);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), s);
    gtk_widget_add_controller(s->card, keys);
    gtk_widget_set_visible(s->card, FALSE);
    g_object_set_data_full(G_OBJECT(s->card), "zg-search", s, search_free);
    g_signal_connect(model, "setting-changed", G_CALLBACK(on_setting_changed), s);
    return s->card;
}

void zg_search_show(GtkWidget *search, const char *text, gint64 part) {
    Search *s = get(search);
    if (!s) return;
    gboolean open = gtk_widget_get_visible(s->card);
    if (!open) place_saved(s);
    s->part = part;
    if (part >= 0) {
        zs_part info;
        char *label = zs_app_part_get(zg_model_core(s->model), (size_t)part, &info) == ZS_OK && info.name && info.name[0]
                          ? g_strdup_printf("Part: %s", info.name)
                          : g_strdup_printf("Part %d", (int)part + 1);
        gtk_label_set_text(GTK_LABEL(s->scope_label), label);
        g_free(label);
        gtk_entry_set_placeholder_text(GTK_ENTRY(s->entry), "Search the settings of this part");
    } else {
        gtk_entry_set_placeholder_text(GTK_ENTRY(s->entry), "Search settings and actions");
    }
    gtk_widget_set_visible(s->scope_label, part >= 0);
    s->filling = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(s->entry), text ? text : "");
    s->filling = FALSE;
    fill(s);
    gtk_widget_set_visible(s->card, TRUE);
    gtk_widget_grab_focus(s->entry);
    gtk_editable_select_region(GTK_EDITABLE(s->entry), 0, -1);
}

void zg_search_close(GtkWidget *search) {
    Search *s = get(search);
    if (!s || !gtk_widget_get_visible(s->card)) return;
    gboolean eye = s->eye_on != NULL;
    g_clear_pointer(&s->eye_on, g_free);
    gtk_widget_set_visible(s->card, FALSE);
    /* The editors go with the rows. */
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(s->list))) gtk_box_remove(GTK_BOX(s->list), child);
    g_ptr_array_set_size(s->rows, 0);
    /* The view shows the whole print again (or the focus of the panel). */
    (void)eye;
    zg_model_set_focus(s->model, 0, FALSE);
    gtk_widget_activate_action(s->card, "win.refocus", NULL);
    /* The keys go to the view. */
    GtkWidget *preview = gtk_widget_get_parent(s->card);
    if (preview) gtk_widget_grab_focus(preview);
}

gboolean zg_search_is_open(GtkWidget *search) {
    return gtk_widget_get_visible(search);
}
