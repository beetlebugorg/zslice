/* search.c: see search.h.
 *
 * The entry and the scope label move between the field of the header
 * (docked) and the head of the card (undocked, while the card shows).
 *
 * The settings come from the search of the core (zs_setting_search): each
 * word of the query must match a setting, by itself or by a word of the
 * same meaning (also the names of other slicers). The actions are the
 * app's own, matched by their words here.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "search.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "../prefs/printers.h"
#include "float.h"
#include "setting-editor.h"

enum { MAX_SETTINGS = 14, MAX_ACTIONS = 4, DRAG_MS = 90 };

/* The first place of the box: at the top of the view, in the middle,
 * under the Search button of the top bar. */
static const double PLACE_Y = 12;
/* The least width of the docked results, and of the card. The least
 * height of the list of the card. */
enum { DOCKED_WIDTH = 560, CARD_WIDTH = 500, MIN_WIDTH = 360, MIN_LIST = 120, LIST_HEIGHT = 520 };


/* The actions in the results: the label, the keys, a hint, and the
 * action with its target (a string, or NULL). */
typedef struct {
    const char *label, *keys, *hint, *action, *target;
} Action;

static const Action ACTIONS[] = {
    {"Open a model…", "Ctrl+O", "add models to the plate", "app.open", NULL},
    {"Export G-code…", "Ctrl+E", NULL, "win.export", NULL},
    {"The print as it forms", NULL, "simulated plastic: it sags and droops where nothing holds it", "preview.simulate", NULL},
    {"Print", NULL, "send the G-code to the printer and start", "win.send-print", NULL},
    {"Upload to the printer", NULL, "send the G-code, and do not start", "win.send-only", NULL},
    {"Arrange the plate", NULL, "pack the parts on the bed", "win.arrange", NULL},
    {"Remove this plate", NULL, "the plate and its parts", "win.remove-plate", NULL},
    {"Smart placement", NULL, "turn and arrange the parts", "win.smart-place", NULL},
    {"Check the print", NULL, "problems and advice", "preview.check", NULL},
    {"Save the project…", "Ctrl+S", "all plates in one 3MF file", "win.save-plate", NULL},
    {"Undo", "Ctrl+Z", NULL, "win.undo", NULL},
    {"Redo", "Ctrl+Shift+Z", NULL, "win.redo", NULL},
    {"2D layer view", "2", NULL, "preview.view", "2d"},
    {"3D view", "3", NULL, "preview.view", "3d"},
    {"Support tool", "U", "draw an area on the part: support under it, or none", "preview.tool", "support"},
    {"Measure tool", "T", "measure between two points of the print", "preview.tool", "measure"},
    {"Label tool", "L", "text and marks on the surface of a part, in another filament", "preview.tool", "label"},
    {"Manage printers…", "Ctrl+,", "preferences, connections, API keys", "win.preferences", NULL},
    {"Compare with Cura…", NULL, NULL, "win.compare-cura", NULL},
    {"Open a project", NULL, "printdeck.yml from GitHub or a folder", "win.show-page", "project"},
    {"History", NULL, "the changes, undo one change", "win.show-page", "history"},
    {"Keyboard shortcuts", "?", NULL, "win.shortcuts", NULL},
    {"All settings", "N", "the panel of the settings", "win.show-page", "settings"},
    {"Printers", NULL, "your printers, their jobs, and the plates to print", "win.show-page", "farm"},
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
    /* The entry in an overlay with a watch of its width (see
     * fit_placeholder), and the full text of the placeholder. */
    GtkWidget *entry_box;
    const char *placeholder;
    /* The header: the field (the icon, the entry, ×, and the undock
     * button), and the Search button of the undocked search. */
    GtkWidget *header, *field, *field_icon, *field_close, *open_button;
    /* The head of the card: the grip, and the resize grip at the lower
     * right corner. */
    GtkWidget *grip, *resize;
    gboolean undocked;
    int drag_w, drag_h; /* the size at the start of a resize */
    GPtrArray *rows; /* Row * */
    guint index;
    gint64 part; /* the part of the search, or -1 */
    char *eye_on; /* the setting whose eye is on, or NULL */
    gboolean filling;
} Search;

static Search *get(GtkWidget *w) {
    return g_object_get_data(G_OBJECT(w), "zg-search");
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
        if (info->kind == ZS_SETTING_INTEGER) v = round(v);
        if (info->limit_max > info->limit_min) v = CLAMP(v, info->limit_min, info->limit_max);
        char core[G_ASCII_DTOSTR_BUF_SIZE];
        g_ascii_formatd(core, sizeof core, "%.10g", v);
        /* The editors of the setting follow the new value. */
        if (s->part >= 0) {
            if (zg_model_part_setting_set(s->model, (size_t)s->part, info->name, core)) zg_model_announce(s->model, info->name);
        } else {
            zg_model_set(s->model, info->name, core, NULL);
        }
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
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD);
    gtk_widget_set_tooltip_text(label, info->doc);
    r->tag = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(r->tag), 0);
    gtk_label_set_wrap(GTK_LABEL(r->tag), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(r->tag), PANGO_WRAP_WORD);
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
    gboolean number = (info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER) && !zg_setting_is_filament(info->name);
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
        gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(hint), PANGO_WRAP_WORD);
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
    /* The ranking of the core (zs_setting_search), the same in each app. */
    GArray *matches = g_array_new(FALSE, FALSE, sizeof(Match));
    enum { MAX_HITS = 400 };
    uint32_t idx[MAX_HITS];
    double sc[MAX_HITS];
    size_t hits = zs_setting_search(q, s->part >= 0, idx, sc, MAX_HITS);
    for (size_t i = 0; i < hits; i++) {
        Match m;
        if (zs_setting_get_info(idx[i], &m.info) != ZS_OK) continue;
        m.score = sc[i];
        g_array_append_val(matches, m);
    }
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

static void show_search(Search *s, const char *text, gint64 part, gboolean focus);

/* Text in the docked field shows the results. */
static void on_changed(GtkEditable *e, gpointer data) {
    Search *s = data;
    if (s->filling) return;
    if (gtk_widget_get_visible(s->card)) fill(s);
    else show_search(s, NULL, -1, FALSE);
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
    if (!gtk_widget_get_visible(s->card)) return FALSE;
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

/* The first place: the middle of the view, at the top. */
static double first_x(Search *s) {
    GtkWidget *host = gtk_widget_get_parent(s->card);
    /* Its width: as allocated, else the least width (a wrapped hint has a
     * natural width of its whole text). */
    int w = gtk_widget_get_width(s->card);
    if (w <= 0) gtk_widget_measure(s->card, GTK_ORIENTATION_HORIZONTAL, -1, &w, NULL, NULL, NULL);
    int W = host ? gtk_widget_get_width(host) : 0;
    return W > 0 ? MAX(64, (W - w) / 2.0) : 64;
}

/* A double click on the head: back to the first place. */
static void on_head_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Search *s = data;
    if (n != 2) return;
    zg_pref_set("search_place", "");
    zg_float_place(s->card, first_x(s), PLACE_Y);
    zg_float_forget(s->card);
}

static void place_saved(Search *s) {
    char *saved = zg_pref_get("search_place", "");
    double x = first_x(s), y = PLACE_Y;
    char **xy = g_strsplit(saved, ",", 2);
    if (xy[0] && xy[1]) {
        x = g_ascii_strtod(xy[0], NULL);
        y = g_ascii_strtod(xy[1], NULL);
    }
    g_strfreev(xy);
    g_free(saved);
    zg_float_place(s->card, x, y);
}

/* The height of the list of the card: at most `h`, and exactly `h` with
 * fixed TRUE (after a resize). */
static void set_list_height(Search *s, int h, gboolean fixed) {
    GtkScrolledWindow *sw = GTK_SCROLLED_WINDOW(s->scroll);
    gtk_scrolled_window_set_min_content_height(sw, -1);
    gtk_scrolled_window_set_max_content_height(sw, h);
    if (fixed) gtk_scrolled_window_set_min_content_height(sw, h);
}

/* The size of the card: the size of the last resize, or the first size. */
static void size_saved(Search *s) {
    char *saved = zg_pref_get("search_size", "");
    char **wh = g_strsplit(saved, ",", 2);
    int w = CARD_WIDTH, h = 0;
    if (wh[0] && wh[1]) {
        w = MAX(MIN_WIDTH, atoi(wh[0]));
        h = MAX(MIN_LIST, atoi(wh[1]));
    }
    g_strfreev(wh);
    g_free(saved);
    /* The card stays inside the view. */
    GtkWidget *host = gtk_widget_get_parent(s->card);
    int W = host ? gtk_widget_get_width(host) : 0;
    if (W > 0) w = MIN(w, MAX(MIN_WIDTH, W - 16));
    gtk_widget_set_size_request(s->card, w, -1);
    set_list_height(s, h > 0 ? h : LIST_HEIGHT, h > 0);
}

/* The docked results: under the field of the header, at least
 * DOCKED_WIDTH wide, in the middle of the field. */
static void place_docked(Search *s) {
    GtkWidget *host = gtk_widget_get_parent(s->card);
    graphene_point_t p;
    int fw = gtk_widget_get_width(s->field), fh = gtk_widget_get_height(s->field);
    int W = host ? gtk_widget_get_width(host) : 0;
    int w = MAX(fw, DOCKED_WIDTH);
    if (W > 0) w = MIN(w, W - 16);
    gtk_widget_set_size_request(s->card, w, -1);
    set_list_height(s, LIST_HEIGHT, FALSE);
    if (!host || !gtk_widget_compute_point(s->field, host, &GRAPHENE_POINT_INIT(fw / 2.0f, (float)fh), &p)) {
        zg_float_place(s->card, first_x(s), PLACE_Y);
        return;
    }
    /* The header is over the view: the top of the view is the place
     * under the field. */
    zg_float_place(s->card, MAX(8, p.x - w / 2.0), MAX(6, p.y + 6));
}

/* A drag of the grip at the lower right corner changes the size of the
 * card. The size stays for the next search. */
static void on_resize_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    Search *s = data;
    s->drag_w = gtk_widget_get_width(s->card);
    s->drag_h = gtk_widget_get_height(s->scroll);
}

static void on_resize_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    Search *s = data;
    gtk_widget_set_size_request(s->card, MAX(MIN_WIDTH, s->drag_w + (int)dx), -1);
    set_list_height(s, MAX(MIN_LIST, s->drag_h + (int)dy), TRUE);
}

static void on_resize_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    Search *s = data;
    char buf[64];
    g_snprintf(buf, sizeof buf, "%d,%d", MAX(MIN_WIDTH, s->drag_w + (int)dx), MAX(MIN_LIST, s->drag_h + (int)dy));
    zg_pref_set("search_size", buf);
}

/* ---- docked and undocked ---- */

/* Moves `w` from its box to the box `to`, after `after` (NULL: first). */
static void move_child(GtkWidget *w, GtkWidget *to, GtkWidget *after) {
    GtkWidget *from = gtk_widget_get_parent(w);
    if (from == to && gtk_widget_get_prev_sibling(w) == after) return;
    g_object_ref(w);
    if (from) gtk_box_remove(GTK_BOX(from), w);
    gtk_box_insert_child_after(GTK_BOX(to), w, after);
    g_object_unref(w);
}

/* The entry and the scope label go into the head of the card (TRUE), or
 * back into the field of the header (FALSE). */
static void move_entry(Search *s, gboolean to_card) {
    if (to_card) {
        move_child(s->scope_label, s->head, s->grip);
        move_child(s->entry_box, s->head, s->scope_label);
    } else {
        move_child(s->scope_label, s->field, s->field_icon);
        move_child(s->entry_box, s->field, s->scope_label);
    }
}

/* The header shows the field (docked), or the Search button (undocked).
 * The card has its head and its resize grip only while undocked. */
static void apply_dock(Search *s) {
    gtk_widget_set_visible(s->field, !s->undocked);
    gtk_widget_set_visible(s->open_button, s->undocked);
    gtk_widget_set_visible(s->head, s->undocked);
    gtk_widget_set_visible(s->resize, s->undocked);
    if (s->undocked) gtk_widget_remove_css_class(s->card, "zg-search-docked");
    else gtk_widget_add_css_class(s->card, "zg-search-docked");
}

/* Docks the search in the header, or undocks it into a card. The search
 * opens again in its new place, with its text. */
static void set_docked(Search *s, gboolean docked) {
    zg_search_close(s->card);
    s->undocked = !docked;
    zg_pref_set("search_docked", docked ? "1" : "0");
    apply_dock(s);
    show_search(s, NULL, -1, TRUE);
}

static void on_undock(GtkButton *b, gpointer data) {
    set_docked(data, FALSE);
}

static void on_dock(GtkButton *b, gpointer data) {
    set_docked(data, TRUE);
}

static void on_open_clicked(GtkButton *b, gpointer data) {
    show_search(data, NULL, -1, TRUE);
}

/* A click in the docked field shows the results. */
static void on_field_press(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Search *s = data;
    if (!s->undocked && !gtk_widget_get_visible(s->card)) show_search(s, NULL, -1, FALSE);
}

static void on_close_clicked(GtkButton *b, gpointer data) {
    zg_search_close(((Search *)data)->card);
}

static void search_free(gpointer data) {
    Search *s = data;
    g_signal_handlers_disconnect_by_data(s->model, s);
    g_ptr_array_free(s->rows, TRUE);
    g_free(s->eye_on);
    g_clear_object(&s->header);
    g_object_unref(s->model);
    g_free(s);
}

static GtkWidget *flat_icon_button(const char *icon, const char *tip) {
    GtkWidget *b = gtk_button_new_from_icon_name(icon);
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_add_css_class(b, "circular");
    gtk_widget_set_tooltip_text(b, tip);
    gtk_widget_set_focus_on_click(b, FALSE);
    return b;
}

/* The placeholder: the full text if it fits in the entry, else
 * "Search". The entry gets narrow in a narrow window, and GTK then cuts
 * the text with "…". */
static void fit_placeholder(Search *s, int width) {
    if (width <= 0) width = gtk_widget_get_width(s->entry_box);
    PangoLayout *layout = gtk_widget_create_pango_layout(s->entry, s->placeholder);
    int tw = 0;
    pango_layout_get_pixel_size(layout, &tw, NULL);
    g_object_unref(layout);
    /* The entry has a padding of about 9 px at each side. */
    const char *text = width <= 0 || tw + 20 <= width ? s->placeholder : "Search";
    const char *now = gtk_entry_get_placeholder_text(GTK_ENTRY(s->entry));
    if (!now || strcmp(now, text) != 0) gtk_entry_set_placeholder_text(GTK_ENTRY(s->entry), text);
}

static void set_placeholder(Search *s, const char *text) {
    s->placeholder = text;
    fit_placeholder(s, 0);
}

static void on_entry_resize(GtkDrawingArea *area, int width, int height, gpointer data) {
    fit_placeholder(data, width);
}

/* The header part: the field, and the Search button of the undocked
 * search. */
static void header_new(Search *s) {
    s->header = g_object_ref_sink(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
    s->field = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(s->field, "zg-search-field");
    gtk_widget_set_tooltip_text(s->field, "Search settings and actions (/). Change a setting right in the results, and watch the slice.");
    s->field_icon = gtk_image_new_from_icon_name("system-search-symbolic");
    gtk_box_append(GTK_BOX(s->field), s->field_icon);
    gtk_box_append(GTK_BOX(s->field), s->scope_label);
    gtk_box_append(GTK_BOX(s->field), s->entry_box);
    s->field_close = flat_icon_button("window-close-symbolic", "Close the search (Esc)");
    gtk_widget_set_visible(s->field_close, FALSE);
    g_signal_connect(s->field_close, "clicked", G_CALLBACK(on_close_clicked), s);
    gtk_box_append(GTK_BOX(s->field), s->field_close);
    GtkWidget *undock = flat_icon_button("window-new-symbolic", "Undock the search: a card over the view that you can move and resize");
    g_signal_connect(undock, "clicked", G_CALLBACK(on_undock), s);
    gtk_box_append(GTK_BOX(s->field), undock);
    GtkGesture *press = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(press), GTK_PHASE_CAPTURE);
    g_signal_connect(press, "pressed", G_CALLBACK(on_field_press), s);
    gtk_widget_add_controller(s->field, GTK_EVENT_CONTROLLER(press));
    /* The keys of the entry in the field: the same keys as in the card. */
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), s);
    gtk_widget_add_controller(s->field, keys);
    gtk_box_append(GTK_BOX(s->header), s->field);
    /* The Search button of the undocked search. */
    s->open_button = gtk_button_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(box), gtk_image_new_from_icon_name("system-search-symbolic"));
    gtk_box_append(GTK_BOX(box), gtk_label_new("Search"));
    GtkWidget *key = gtk_label_new("/");
    gtk_widget_add_css_class(key, "zg-keycap");
    gtk_box_append(GTK_BOX(box), key);
    gtk_button_set_child(GTK_BUTTON(s->open_button), box);
    gtk_widget_set_tooltip_text(s->open_button, "Search settings and actions (/). Change a setting right in the results, and watch the slice.");
    gtk_widget_set_focus_on_click(s->open_button, FALSE);
    g_signal_connect(s->open_button, "clicked", G_CALLBACK(on_open_clicked), s);
    gtk_box_append(GTK_BOX(s->header), s->open_button);
}

GtkWidget *zg_search_new(ZgModel *model) {
    Search *s = g_new0(Search, 1);
    s->model = g_object_ref(model);
    s->rows = g_ptr_array_new_with_free_func(g_free);
    s->part = -1;
    s->card = zg_card_new();
    gtk_widget_add_css_class(s->card, "zg-search");
    /* The scope (a part) and the entry: in the field of the header, or in
     * the head of the card. */
    s->scope_label = gtk_label_new("");
    gtk_widget_add_css_class(s->scope_label, "zg-sr-scope");
    gtk_label_set_wrap(GTK_LABEL(s->scope_label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(s->scope_label), PANGO_WRAP_WORD_CHAR);
    gtk_widget_set_visible(s->scope_label, FALSE);
    s->entry = gtk_entry_new();
    gtk_widget_set_hexpand(s->entry, TRUE);
    s->entry_box = gtk_overlay_new();
    gtk_widget_set_hexpand(s->entry_box, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(s->entry_box), s->entry);
    GtkWidget *watch = gtk_drawing_area_new();
    gtk_widget_set_can_target(watch, FALSE);
    g_signal_connect(watch, "resize", G_CALLBACK(on_entry_resize), s);
    gtk_overlay_add_overlay(GTK_OVERLAY(s->entry_box), watch);
    set_placeholder(s, "Search settings and actions");
    /* A narrow window: the entry gets narrower before the menus of the
     * header lose room. */
    gtk_editable_set_width_chars(GTK_EDITABLE(s->entry), 6);
    g_signal_connect(s->entry, "changed", G_CALLBACK(on_changed), s);
    /* The head of the undocked card: a grip, the scope, the entry, the
     * dock button, and ×. */
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(head, "zg-card-head");
    s->grip = gtk_image_new_from_icon_name("system-search-symbolic");
    gtk_widget_set_tooltip_text(s->grip, "Drag to move the search. Double-click: back to its first place.");
    gtk_box_append(GTK_BOX(head), s->grip);
    GtkWidget *dock = flat_icon_button("go-top-symbolic", "Dock the search: put it back in the header");
    g_signal_connect(dock, "clicked", G_CALLBACK(on_dock), s);
    gtk_box_append(GTK_BOX(head), dock);
    GtkWidget *close = flat_icon_button("window-close-symbolic", "Close the search (Esc)");
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
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(s->scroll), LIST_HEIGHT);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s->scroll), s->list);
    gtk_box_append(GTK_BOX(s->card), s->scroll);
    /* The resize grip, at the lower right corner of the card. */
    s->resize = gtk_image_new_from_icon_name("list-drag-handle-symbolic");
    gtk_widget_add_css_class(s->resize, "zg-resize-grip");
    gtk_widget_set_halign(s->resize, GTK_ALIGN_END);
    gtk_widget_set_cursor_from_name(s->resize, "se-resize");
    gtk_widget_set_tooltip_text(s->resize, "Drag to change the size of the search");
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_resize_begin), s);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_resize_update), s);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_resize_end), s);
    gtk_widget_add_controller(s->resize, GTK_EVENT_CONTROLLER(drag));
    gtk_box_append(GTK_BOX(s->card), s->resize);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), s);
    gtk_widget_add_controller(s->card, keys);
    gtk_widget_set_visible(s->card, FALSE);
    header_new(s);
    char *docked = zg_pref_get("search_docked", "1");
    s->undocked = strcmp(docked, "0") == 0;
    g_free(docked);
    apply_dock(s);
    g_object_set_data_full(G_OBJECT(s->card), "zg-search", s, search_free);
    g_signal_connect(model, "setting-changed", G_CALLBACK(on_setting_changed), s);
    return s->card;
}

GtkWidget *zg_search_header(GtkWidget *search) {
    Search *s = get(search);
    return s ? s->header : NULL;
}

/* text NULL keeps the text of the entry. focus FALSE: the user types in
 * the field, and the focus stays there. */
static void show_search(Search *s, const char *text, gint64 part, gboolean focus) {
    gboolean was_open = gtk_widget_get_visible(s->card);
    /* Another scope: the search starts again. */
    if (was_open && part != s->part) {
        zg_search_close(s->card);
        was_open = FALSE;
    }
    s->part = part;
    if (part >= 0) {
        zs_part info;
        char *label = zs_app_part_get(zg_model_core(s->model), (size_t)part, &info) == ZS_OK && info.name && info.name[0]
                          ? g_strdup_printf("Part: %s", info.name)
                          : g_strdup_printf("Part %d", (int)part + 1);
        gtk_label_set_text(GTK_LABEL(s->scope_label), label);
        g_free(label);
        set_placeholder(s, "Search the settings of this part");
    } else {
        set_placeholder(s, "Search settings and actions");
    }
    gtk_widget_set_visible(s->scope_label, part >= 0);
    if (text) {
        s->filling = TRUE;
        gtk_editable_set_text(GTK_EDITABLE(s->entry), text);
        s->filling = FALSE;
    }
    if (s->undocked) {
        move_entry(s, TRUE);
        if (!was_open) size_saved(s);
    } else {
        gtk_widget_set_visible(s->field_close, TRUE);
        gtk_widget_add_css_class(s->field, "zg-open");
    }
    fill(s);
    gtk_widget_set_visible(s->card, TRUE);
    /* After the show: the card has its width for the middle. */
    if (!was_open) {
        if (s->undocked) place_saved(s);
        else place_docked(s);
    }
    if (focus || s->undocked) {
        gtk_widget_grab_focus(s->entry);
        if (focus) gtk_editable_select_region(GTK_EDITABLE(s->entry), 0, -1);
    }
}

void zg_search_show(GtkWidget *search, const char *text, gint64 part) {
    Search *s = get(search);
    if (s) show_search(s, text, part, TRUE);
}

void zg_search_close(GtkWidget *search) {
    Search *s = get(search);
    if (!s || !gtk_widget_get_visible(s->card)) return;
    g_clear_pointer(&s->eye_on, g_free);
    gtk_widget_set_visible(s->card, FALSE);
    /* The editors go with the rows. */
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(s->list))) gtk_box_remove(GTK_BOX(s->list), child);
    g_ptr_array_set_size(s->rows, 0);
    /* The entry goes back to the field of the header. */
    move_entry(s, FALSE);
    s->part = -1;
    gtk_widget_set_visible(s->scope_label, FALSE);
    set_placeholder(s, "Search settings and actions");
    gtk_widget_set_visible(s->field_close, FALSE);
    gtk_widget_remove_css_class(s->field, "zg-open");
    /* The view shows the whole print again (or the focus of the panel). */
    zg_model_set_focus(s->model, 0, FALSE);
    gtk_widget_activate_action(s->card, "win.refocus", NULL);
    /* The keys go to the view. */
    GtkWidget *preview = gtk_widget_get_parent(s->card);
    if (preview) gtk_widget_grab_focus(preview);
}

gboolean zg_search_is_open(GtkWidget *search) {
    return gtk_widget_get_visible(search);
}
