/* line-card.c: see line-card.h.
 *
 * The settings of the card come from what the line is and what happens to
 * it (pick_settings, as contextSettings of web/app/linecard.js): first the
 * reasons of this line (slow, the first layer, a change of the user), then
 * the main settings of its feature, then the other settings that change
 * the line (zs_inspect.settings).
 *
 * The Filament row gives the body of the line on its layer its own
 * filament (zg_view3d_paint_line: the lines joined to it, as paint of its
 * part). Then the card offers the layers above and below where the body
 * goes on (zs_view_connected_layers), with the beads that the pick took
 * before the slice numbered the lines again.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "line-card.h"

#include <string.h>

#include "../prefs/printers.h"
#include "filaments.h"
#include "float.h"
#include "preview.h"
#include "setting-editor.h"
#include "view3d.h"
#include "widgets.h"

enum { MAX_PICKS = 4 };

typedef struct {
    char *name;
    const char *why;
} Pick;

typedef struct {
    ZgModel *model;
    GtkWidget *preview, *card, *title, *stats, *note, *size, *settings, *fade;
    gboolean want;      /* a click opened it: show the next selection */
    gboolean in_panel;  /* All settings put the line in the panel */
    char *signature;    /* the title and the settings of the line shown */
    double at_x, at_y;  /* the point of the click */
    gboolean quiet;
    /* The Filament row: its chips, the filament of the line, the buttons
     * of the layers above and below, and the body of the last pick. */
    GtkWidget *fil_chips, *extend;
    int fil_value;
    ZgLineBody body;
} LineCard;

static void fil_chips_draw(LineCard *c);

static void pick_free(gpointer data) {
    Pick *p = data;
    g_free(p->name);
    g_free(p);
}

/* The settings for the card, from the core (zs_app_inspect_picks): why
 * the line is slow, the first layer, the user's changes, then the main
 * settings of its feature. [{name, why}]. */
static GPtrArray *pick_settings(LineCard *c, const zs_inspect *info) {
    GPtrArray *out = g_ptr_array_new_with_free_func(pick_free);
    zs_pick picks[MAX_PICKS];
    size_t n = 0;
    if (zs_app_inspect_picks(zg_model_core(c->model), info->path, picks, MAX_PICKS, &n) != ZS_OK) return out;
    for (size_t i = 0; i < n; i++) {
        Pick *p = g_new0(Pick, 1);
        p->name = g_strdup(picks[i].name);
        p->why = picks[i].why;
        g_ptr_array_add(out, p);
    }
    return out;
}

static void stat_box(GtkWidget *grid, int col, const char *value, const char *caption, gboolean warn) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(box, "zg-stat");
    gtk_widget_set_hexpand(box, TRUE);
    GtkWidget *v = gtk_label_new(value);
    gtk_widget_add_css_class(v, "zg-stat-value");
    if (warn) gtk_widget_add_css_class(v, "warning");
    GtkWidget *k = gtk_label_new(caption);
    gtk_widget_add_css_class(k, "zg-stat-caption");
    gtk_box_append(GTK_BOX(box), v);
    gtk_box_append(GTK_BOX(box), k);
    gtk_grid_attach(GTK_GRID(grid), box, col, 0, 1, 1);
}

/* The numbers of the line: its title, the three numbers, why it is slow,
 * and its size. */
static void update_numbers(LineCard *c, const zs_inspect *info, size_t path) {
    /* A printer with two nozzles: the nozzle of the line. */
    const char *nozzle = info->nozzle == 2 ? " · 2nd nozzle" : info->nozzle == 1 ? " · main nozzle" : "";
    char *title = g_strdup_printf("%s · layer %zu%s", info->title, info->layer + 1, nozzle);
    gtk_label_set_text(GTK_LABEL(c->title), title);
    g_free(title);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->stats))) gtk_grid_remove(GTK_GRID(c->stats), child);
    char a[32], b[32], f[32];
    g_snprintf(a, sizeof a, "%.0f mm/s", info->planned_speed);
    g_snprintf(b, sizeof b, "%.0f mm/s", info->speed);
    g_snprintf(f, sizeof f, "%.1f mm³/s", info->flow);
    stat_box(c->stats, 0, a, "planned", FALSE);
    stat_box(c->stats, 1, b, "real", info->slow_reason != 0);
    stat_box(c->stats, 2, f, "flow", FALSE);
    /* Why it is slow, and the speed limits of the second nozzle. */
    const char *slow = info->slow_text ? info->slow_text : "";
    const char *limits = info->nozzle == 2 && info->nozzle_text ? info->nozzle_text : "";
    char *note = g_strdup_printf("%s%s%s", slow, slow[0] && limits[0] ? "\n" : "", limits);
    gtk_label_set_text(GTK_LABEL(c->note), note);
    gtk_widget_set_visible(c->note, note[0] != 0);
    g_free(note);
    /* The size: a circle or an arc, the segment, and the path. */
    gint64 seg = zg_model_segment(c->model);
    zs_measure m;
    if (zs_app_measure(zg_model_core(c->model), path, seg < 0 ? 0 : (size_t)seg, &m) == ZS_OK) {
        GString *s = g_string_new(NULL);
        if (m.shape == 1) g_string_append_printf(s, "Circle ⌀ %.2f mm · ", 2 * m.radius);
        else if (m.shape == 2) g_string_append_printf(s, "Arc r %.2f mm · ", m.radius);
        g_string_append_printf(s, "segment %.2f mm · %s %.1f mm", m.segment_length, m.closed ? "loop" : "path", m.path_length);
        gtk_label_set_text(GTK_LABEL(c->size), s->str);
        g_string_free(s, TRUE);
        gtk_widget_set_visible(c->size, TRUE);
    } else {
        gtk_widget_set_visible(c->size, FALSE);
    }
}

static void fill_settings(LineCard *c, const zs_inspect *info) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->settings))) gtk_grid_remove(GTK_GRID(c->settings), child);
    GPtrArray *picks = pick_settings(c, info);
    gtk_widget_set_visible(c->settings, picks->len > 0);
    for (guint i = 0; i < picks->len; i++) {
        Pick *p = g_ptr_array_index(picks, i);
        zs_setting_info s;
        if (!zg_setting_find(p->name, &s)) continue;
        GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(labels, TRUE);
        GtkWidget *name = gtk_label_new(s.label);
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        gtk_label_set_wrap(GTK_LABEL(name), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(name), PANGO_WRAP_WORD);
        gtk_widget_set_tooltip_text(name, zg_doc_plain(s.doc));
        gtk_box_append(GTK_BOX(labels), name);
        if (p->why[0]) {
            GtkWidget *why = gtk_label_new(p->why);
            gtk_label_set_xalign(GTK_LABEL(why), 0);
            gtk_widget_add_css_class(why, "zg-lc-why");
            gtk_box_append(GTK_BOX(labels), why);
        }
        GtkWidget *editor = zg_setting_editor_new(c->model, &s, FALSE);
        gtk_grid_attach(GTK_GRID(c->settings), labels, 0, (int)i, 1, 1);
        gtk_grid_attach(GTK_GRID(c->settings), editor, 1, (int)i, 1, 1);
        if (s.unit[0] && (s.kind == ZS_SETTING_NUMBER || s.kind == ZS_SETTING_INTEGER)) {
            GtkWidget *unit = gtk_label_new(s.unit);
            gtk_label_set_xalign(GTK_LABEL(unit), 0);
            gtk_widget_add_css_class(unit, "dim-label");
            gtk_widget_add_css_class(unit, "zg-unit");
            zg_setting_editor_show_speed(editor, unit);
            gtk_grid_attach(GTK_GRID(c->settings), unit, 2, (int)i, 1, 1);
        }
    }
    g_ptr_array_free(picks, TRUE);
}

/* Next to the click, inside the view (a card that the user moved stays). */
static void place(LineCard *c) {
    if (zg_float_user_moved(c->card)) return;
    int w = 0, h = 0;
    gtk_widget_measure(c->card, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &w, NULL, NULL);
    gtk_widget_measure(c->card, GTK_ORIENTATION_VERTICAL, w, NULL, &h, NULL, NULL);
    /* The box of the whole line that the user clicked, and the click: the
     * card covers no part of it. */
    double box[4] = {c->at_x, c->at_y, c->at_x, c->at_y}, r[4], area[4], x, y;
    if (zg_view3d_path_rect(zg_preview_view3d(c->preview), zg_model_selected(c->model), r)) {
        box[0] = MIN(box[0], r[0]);
        box[1] = MIN(box[1], r[1]);
        box[2] = MAX(box[2], r[2]);
        box[3] = MAX(box[3], r[3]);
    }
    box[0] -= 12;
    box[1] -= 12;
    box[2] += 12;
    box[3] += 12;
    zg_free_area(c->preview, area);
    zg_place_beside(box, area, w, h, &x, &y);
    zg_float_place(c->card, x, y);
}

static gboolean on_fil_idle(gpointer data) {
    fil_chips_draw(data);
    return G_SOURCE_REMOVE;
}

/* "Also the layers above" (dir 1) and "below" (dir -1): the beads that
 * the pick took. */
static void on_extend(GtkButton *b, gpointer data) {
    LineCard *c = data;
    int dir = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-dir"));
    const float *beads = dir > 0 ? c->body.above : c->body.below;
    size_t n = dir > 0 ? c->body.n_above : c->body.n_below;
    if (!beads || !zg_view3d_paint_beads(zg_preview_view3d(c->preview), beads, n, c->fil_value)) return;
    gtk_widget_set_visible(GTK_WIDGET(b), FALSE);
}

static void clear_extend(LineCard *c) {
    zg_line_body_free(&c->body);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->extend))) gtk_box_remove(GTK_BOX(c->extend), child);
    gtk_widget_set_visible(c->extend, FALSE);
}

static void extend_button(LineCard *c, int dir, const char *text, const char *tip) {
    GtkWidget *b = gtk_button_new_with_label(text);
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_set_tooltip_text(b, tip);
    gtk_widget_set_halign(b, GTK_ALIGN_START);
    g_object_set_data(G_OBJECT(b), "zg-dir", GINT_TO_POINTER(dir));
    g_signal_connect(b, "clicked", G_CALLBACK(on_extend), c);
    gtk_box_append(GTK_BOX(c->extend), b);
}

/* A chip of the Filament row: the body of the line on its layer gets the
 * filament, and the buttons of the layers where it goes on show. */
static void pick_filament(LineCard *c, int f) {
    gint64 path = zg_model_selected(c->model);
    if (f < 1 || path < 0) return;
    clear_extend(c);
    if (!zg_view3d_paint_line(zg_preview_view3d(c->preview), path, f, &c->body)) return;
    c->fil_value = f;
    if (c->body.above) {
        char *t = g_strdup_printf("Also the layers above, to %zu", c->body.hi + 1);
        char *tip = g_strdup_printf("The same filament for this body on layers %zu to %zu, where it goes on", c->body.layer + 2, c->body.hi + 1);
        extend_button(c, 1, t, tip);
        g_free(tip);
        g_free(t);
    }
    if (c->body.below) {
        char *t = g_strdup_printf("Also the layers below, from %zu", c->body.lo + 1);
        char *tip = g_strdup_printf("The same filament for this body on layers %zu to %zu, where it goes on", c->body.lo + 1, c->body.layer);
        extend_button(c, -1, t, tip);
        g_free(tip);
        g_free(t);
    }
    gtk_widget_set_visible(c->extend, c->body.above || c->body.below);
    g_idle_add(on_fil_idle, c);
}

static void on_fil_chip(GtkButton *b, gpointer data) {
    LineCard *c = data;
    pick_filament(c, zg_filament_chip_pick(b, c->model));
}

void zg_line_card_pick_filament(GtkWidget *card, int filament) {
    LineCard *c = card ? g_object_get_data(G_OBJECT(card), "zg-line-card") : NULL;
    if (c) pick_filament(c, filament);
}

GtkWidget *zg_line_card_of(GtkWidget *widget) {
    for (GtkWidget *w = widget; w; w = gtk_widget_get_parent(w)) {
        GtkWidget *card = g_object_get_data(G_OBJECT(w), "zg-line-card-of");
        if (card) return card;
    }
    return NULL;
}

static void fil_chips_draw(LineCard *c) {
    zg_filament_chips_fill(c->fil_chips, c->model, c->fil_value, "This part of the layer", G_CALLBACK(on_fil_chip), c);
}

static void on_filaments_changed(GtkWidget *owner) {
    LineCard *c = g_object_get_data(G_OBJECT(owner), "zg-line-card");
    if (c && gtk_widget_get_visible(c->card)) fil_chips_draw(c);
}

static void close_card(LineCard *c) {
    c->want = FALSE;
    g_clear_pointer(&c->signature, g_free);
    zg_float_forget(c->card);
    gtk_widget_set_visible(c->card, FALSE);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->settings))) gtk_grid_remove(GTK_GRID(c->settings), child);
}

/* The data of the selected line (zs_app_inspect): build the card, or
 * update its numbers for the same line after a new slice. */
static void show(LineCard *c, gint64 path) {
    zs_inspect info;
    if (path < 0 || zs_app_inspect(zg_model_core(c->model), (size_t)path, &info) != ZS_OK) {
        close_card(c);
        return;
    }
    char *sig = g_strdup_printf("%s\n%s", info.title, info.settings ? info.settings : "");
    gboolean same = c->signature && strcmp(sig, c->signature) == 0 && gtk_widget_get_visible(c->card);
    if (!same) {
        g_free(c->signature);
        c->signature = sig;
        fill_settings(c, &info);
    } else {
        g_free(sig);
    }
    update_numbers(c, &info, (size_t)path);
    int f = (int)zs_app_path_filament(zg_model_core(c->model), (size_t)path);
    if (f > 0 && f != c->fil_value) {
        c->fil_value = f;
        fil_chips_draw(c);
    } else if (!same) {
        fil_chips_draw(c);
    }
    c->quiet = TRUE;
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->fade), zg_model_isolate(c->model));
    c->quiet = FALSE;
    gtk_widget_set_visible(c->card, TRUE);
    if (!same) place(c);
}

/* A click on a line (not a new pick after a slice) opens the card at the
 * click. */
static void on_picked(ZgModel *model, gint64 path, gpointer data) {
    LineCard *c = data;
    /* The Measure tool selects the circle that it measures: the readout
     * says what it is, and no card covers it. */
    if (path < 0 || zg_model_tool(model) == ZG_TOOL_MEASURE) return;
    double x, y;
    zg_preview_pick_point(c->preview, &x, &y);
    /* A new click: the card goes next to it. The keys (h, j, k, l) move
     * the selection, and the card stays where it is. */
    if (!c->want || !gtk_widget_get_visible(c->card) || x != c->at_x || y != c->at_y) {
        /* Another line: no buttons of the body of the line before. */
        clear_extend(c);
        zg_float_forget(c->card);
        g_clear_pointer(&c->signature, g_free);
        c->at_x = x;
        c->at_y = y;
    }
    c->want = TRUE;
    c->in_panel = FALSE;
    show(c, path);
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    LineCard *c = data;
    if (path < 0) {
        close_card(c);
        return;
    }
    if (c->want && gtk_widget_get_visible(c->card)) show(c, path);
}

/* A close of the card: with the line in the panel (All settings), only the
 * card goes, and the panel keeps the line; else the selection clears. */
static void on_close(GtkButton *b, gpointer data) {
    LineCard *c = data;
    if (c->in_panel) close_card(c);
    else zg_model_select(c->model, -1);
}

/* The edit buttons of the card: kind and value by the button. */
static void on_edit(GtkButton *b, gpointer data) {
    LineCard *c = data;
    static const int kinds[] = {0, 1, 1};
    static const double values[] = {1, 0.9, 1.1};
    int k = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-edit"));
    zg_model_edit_line(c->model, zg_model_selected(c->model), kinds[k], values[k]);
}

static void on_fade(GtkToggleButton *b, gpointer data) {
    LineCard *c = data;
    if (c->quiet) return;
    gboolean on = gtk_toggle_button_get_active(b);
    zg_pref_set("isolate", on ? "1" : "0");
    zg_model_set_isolate(c->model, on);
}

/* All settings: the long form of the line in the panel takes the place of
 * the card; the line stays selected. */
static void on_more(GtkButton *b, gpointer data) {
    LineCard *c = data;
    gtk_widget_activate_action_variant(c->card, "win.show-page", g_variant_new_string("selected"));
    close_card(c);
    c->in_panel = TRUE;
}

static gboolean on_key(GtkEventControllerKey *k, guint key, guint code, GdkModifierType mods, gpointer data) {
    LineCard *c = data;
    if (key != GDK_KEY_Escape) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(c->card));
    if (focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    zg_model_select(c->model, -1);
    gtk_widget_grab_focus(c->preview);
    return TRUE;
}

static void card_free(gpointer data) {
    LineCard *c = data;
    g_signal_handlers_disconnect_by_data(c->model, c);
    zg_line_body_free(&c->body);
    g_free(c->signature);
    g_object_unref(c->model);
    g_free(c);
}

GtkWidget *zg_line_card_new(ZgModel *model, GtkWidget *preview) {
    LineCard *c = g_new0(LineCard, 1);
    c->model = g_object_ref(model);
    c->preview = preview;
    c->card = zg_card_new();
    gtk_widget_add_css_class(c->card, "zg-line-card");
    gtk_widget_set_size_request(c->card, 320, -1);
    GtkWidget *head;
    c->title = zg_card_head(c->card, &head, NULL, G_CALLBACK(on_close), c);
    gtk_widget_set_tooltip_text(head, "Drag to move the card");
    zg_float_movable(c->card, head, NULL, NULL);
    c->stats = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(c->stats), 6);
    gtk_grid_set_column_homogeneous(GTK_GRID(c->stats), TRUE);
    gtk_box_append(GTK_BOX(c->card), c->stats);
    c->note = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->note), 0);
    gtk_label_set_wrap(GTK_LABEL(c->note), TRUE);
    gtk_widget_add_css_class(c->note, "zg-note");
    gtk_box_append(GTK_BOX(c->card), c->note);
    c->size = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->size), 0);
    gtk_label_set_wrap(GTK_LABEL(c->size), TRUE);
    gtk_widget_add_css_class(c->size, "dim-label");
    gtk_widget_add_css_class(c->size, "caption");
    gtk_widget_add_css_class(c->size, "numeric");
    gtk_box_append(GTK_BOX(c->card), c->size);
    /* The Filament row (see the top of the file). */
    GtkWidget *fil_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(fil_row, 4);
    GtkWidget *fil_labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(fil_labels, TRUE);
    GtkWidget *fil_name = gtk_label_new("Filament");
    gtk_label_set_xalign(GTK_LABEL(fil_name), 0);
    gtk_widget_set_tooltip_text(fil_name, "A filament for the body of this line on its layer only: the lines joined to it. The paint of the part keeps it.");
    GtkWidget *fil_why = gtk_label_new("This part of the layer");
    gtk_label_set_xalign(GTK_LABEL(fil_why), 0);
    gtk_widget_add_css_class(fil_why, "zg-lc-why");
    gtk_box_append(GTK_BOX(fil_labels), fil_name);
    gtk_box_append(GTK_BOX(fil_labels), fil_why);
    c->fil_chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_widget_set_valign(c->fil_chips, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(fil_row), fil_labels);
    gtk_box_append(GTK_BOX(fil_row), c->fil_chips);
    gtk_box_append(GTK_BOX(c->card), fil_row);
    c->extend = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_visible(c->extend, FALSE);
    gtk_box_append(GTK_BOX(c->card), c->extend);
    c->settings = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(c->settings), 4);
    gtk_grid_set_column_spacing(GTK_GRID(c->settings), 6);
    gtk_widget_set_margin_top(c->settings, 4);
    gtk_box_append(GTK_BOX(c->card), c->settings);
    GtkWidget *foot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(foot, 4);
    c->fade = gtk_toggle_button_new_with_label("Fade the others");
    gtk_widget_set_tooltip_text(c->fade, "Show this line solid, and the other lines as faint ghosts");
    g_signal_connect(c->fade, "toggled", G_CALLBACK(on_fade), c);
    GtkWidget *more = gtk_button_new_with_label("All settings…");
    gtk_widget_add_css_class(more, "flat");
    gtk_widget_set_tooltip_text(more, "All the settings of this line, and how its values come about (the Selected page of the panel)");
    g_signal_connect(more, "clicked", G_CALLBACK(on_more), c);
    gtk_box_append(GTK_BOX(foot), c->fade);
    gtk_box_append(GTK_BOX(foot), more);
    gtk_box_append(GTK_BOX(c->card), foot);
    /* The segment editor: an edit of this line alone, kept across slices. */
    GtkWidget *edits = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    static const struct { const char *label, *tip; int kind; double value; } eds[] = {
        {"Don't print this line", "Take this line out of the print (Delete). The edit stays, and applies again to a new slice that makes the same line.", 0, 1},
        {"−10 % plastic", "This line with 10 % less plastic", 1, 0.9},
        {"+10 % plastic", "This line with 10 % more plastic, for a gap", 1, 1.1},
    };
    for (size_t k = 0; k < G_N_ELEMENTS(eds); k++) {
        GtkWidget *b = gtk_button_new_with_label(eds[k].label);
        gtk_widget_add_css_class(b, "flat");
        gtk_widget_set_tooltip_text(b, eds[k].tip);
        g_object_set_data(G_OBJECT(b), "zg-edit", GINT_TO_POINTER((int)k));
        g_signal_connect(b, "clicked", G_CALLBACK(on_edit), c);
        gtk_box_append(GTK_BOX(edits), b);
    }
    gtk_box_append(GTK_BOX(c->card), edits);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(c->card, keys);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-line-card", c, card_free);
    g_object_set_data(G_OBJECT(preview), "zg-line-card-of", c->card);
    zg_filaments_follow(model, c->card, FALSE, on_filaments_changed);
    g_signal_connect(model, "picked", G_CALLBACK(on_picked), c);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), c);
    return c->card;
}
