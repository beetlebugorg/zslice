/* range-card.c: see range-card.h.
 *
 * The editors are scoped (zg_setting_editor_new with scoped TRUE): they
 * read the value at the first layer and set an override for the range.
 * The card sets the scope of the model when it opens, and clears it when
 * it closes. The card does no work for each frame but its place: 8
 * projections (zg_view3d_on_frame).
 *
 * A lit body (a drag from a line, or Shift+K from a selected line) gets
 * the row "This part of the layers" first: a chip paints the body with
 * that filament (zg_view3d_paint_body). The row of project.filament then
 * reads "Whole layers".
 *
 * With a lit body, each other row has a switch: "This part" (the default)
 * or "Whole layers". The editor of "This part" sets the setting of the
 * region of the body (zg_view3d_region_set: a modifier volume of the
 * part). A setting that a region cannot have (zs_setting_region_note)
 * stays for the whole layers, and a line under its row says why.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "range-card.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "float.h"
#include "preview.h"
#include "setting-editor.h"
#include "view3d.h"
#include "widgets.h"

/* The settings of the card, in order, when the setting can change for
 * some layers (as RANGE_SETTINGS of web/app/rangecard.js). */
static const char *const SETTINGS[] = {
    "project.filament", "project.infill_density", "project.infill_pattern", "project.wall_count", "project.top_thickness",
    "project.outer_wall_speed", "project.infill_speed", "filament.fan_speed", "filament.nozzle_temp",
};

typedef struct {
    ZgModel *model;
    GtkWidget *preview, *card, *title, *facts, *settings;
    /* The row of the filament of a lit body, its chips, and the filament
     * that the user gave the body (0: none yet). */
    GtkWidget *body_row, *body_chips;
    int body_value;
    /* The region of the lit body (0: none yet), and the rows that the
     * user switched to the whole layers (names). */
    guint32 region;
    GHashTable *whole;
    size_t lo, hi;
    gboolean open;
} RangeCard;

static void fill(RangeCard *c);

static void body_chips_draw(RangeCard *c);

static gboolean on_body_idle(gpointer data) {
    RangeCard *c = data;
    body_chips_draw(c);
    return G_SOURCE_REMOVE;
}

static void on_body_chip(GtkButton *b, gpointer data) {
    RangeCard *c = data;
    int f = zg_filament_chip_pick(b, c->model);
    if (f < 1) return;
    if (!zg_view3d_paint_body(zg_preview_view3d(c->preview), f)) return;
    c->body_value = f;
    /* Not in the click of the chip that goes. */
    g_idle_add(on_body_idle, c);
}

/* The chips of the body: one for each filament of the plate, and "+". */
static void body_chips_draw(RangeCard *c) {
    zg_filament_chips_fill(c->body_chips, c->model, c->body_value, "This part of the layers", G_CALLBACK(on_body_chip), c);
}

static void on_filaments_changed(GtkWidget *owner) {
    RangeCard *c = g_object_get_data(G_OBJECT(owner), "zg-range-card");
    if (c && c->open) body_chips_draw(c);
}

static gboolean layer_z(RangeCard *c, size_t layer, double *top, double *bottom) {
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(c->model), &tp) != ZS_OK || tp.layer_count == 0) return FALSE;
    size_t l = MIN(layer, tp.layer_count - 1);
    *top = tp.layer_z[l];
    *bottom = l > 0 ? tp.layer_z[l - 1] : tp.layer_z[0] - (tp.layer_height ? tp.layer_height[0] : 0);
    return TRUE;
}

/* Beside the lit layers: the box of the print from the bottom of the
 * first layer to the top of the last, on the screen. */
static void place(gpointer data) {
    RangeCard *c = data;
    if (!c->open || zg_float_user_moved(c->card)) return;
    GtkWidget *v3 = zg_preview_view3d(c->preview);
    double b[4], t0, b0, t1, b1;
    if (!zg_view3d_bounds(v3, b) || !layer_z(c, c->lo, &t0, &b0) || !layer_z(c, c->hi, &t1, &b1)) return;
    double box[4] = {INFINITY, INFINITY, -INFINITY, -INFINITY}, area[4], x, y;
    for (int k = 0; k < 8; k++) {
        double qx, qy;
        if (!zg_view3d_pixel_of(v3, k & 1 ? b[2] : b[0], k & 2 ? b[3] : b[1], k & 4 ? t1 : b0, &qx, &qy)) continue;
        box[0] = MIN(box[0], qx);
        box[1] = MIN(box[1], qy);
        box[2] = MAX(box[2], qx);
        box[3] = MAX(box[3], qy);
    }
    if (!(box[0] <= box[2])) return;
    int w = 0, h = 0;
    gtk_widget_measure(c->card, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &w, NULL, NULL);
    gtk_widget_measure(c->card, GTK_ORIENTATION_VERTICAL, w, NULL, &h, NULL, NULL);
    zg_free_area(c->preview, area);
    zg_place_beside(box, area, w, h, &x, &y);
    double ox, oy;
    if (zg_float_get(c->card, &ox, &oy) && fabs(ox - x) < 0.5 && fabs(oy - y) < 0.5) return;
    zg_float_place(c->card, x, y);
}

/* The value of a setting of the region of the lit body, or NULL. */
static char *region_get(gpointer data, const char *name) {
    RangeCard *c = data;
    return zg_model_region_value(c->model, c->region, name);
}

static gboolean region_set(gpointer data, const char *name, const char *value) {
    RangeCard *c = data;
    return zg_view3d_region_set(zg_preview_view3d(c->preview), &c->region, name, value);
}

/* Not in the click of the button that goes. */
static gboolean on_fill_idle(gpointer data) {
    RangeCard *c = data;
    if (c->open) fill(c);
    return G_SOURCE_REMOVE;
}

/* The switch of a row: this part of the layers, or the whole layers. */
static void on_scope(GtkButton *b, gpointer data) {
    RangeCard *c = data;
    const char *name = g_object_get_data(G_OBJECT(b), "zg-name");
    if (g_hash_table_contains(c->whole, name)) g_hash_table_remove(c->whole, name);
    else g_hash_table_add(c->whole, g_strdup(name));
    g_idle_add(on_fill_idle, c);
}

/* The region has no value of its own for the setting of the button. */
static void on_region_reset(GtkButton *b, gpointer data) {
    RangeCard *c = data;
    region_set(c, g_object_get_data(G_OBJECT(b), "zg-name"), NULL);
    g_idle_add(on_fill_idle, c);
}

static GtkWidget *small_label(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD_CHAR);
    gtk_widget_add_css_class(l, "caption");
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

static void fill(RangeCard *c) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->settings))) gtk_grid_remove(GTK_GRID(c->settings), child);
    gboolean body = gtk_widget_get_visible(c->body_row);
    int row = 0;
    for (size_t i = 0; i < G_N_ELEMENTS(SETTINGS); i++) {
        zs_setting_info s;
        if (!zg_setting_find(SETTINGS[i], &s) || !s.per_layer) continue;
        gboolean fil = strcmp(s.name, "project.filament") == 0;
        const char *note = zs_setting_region_note(s.name);
        gboolean regional = !fil && !note;
        gboolean part = body && regional && !g_hash_table_contains(c->whole, s.name);
        GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(labels, TRUE);
        GtkWidget *name = gtk_label_new(fil && body ? "Whole layers" : s.label);
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        gtk_label_set_wrap(GTK_LABEL(name), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(name), PANGO_WRAP_WORD);
        gtk_widget_set_tooltip_text(name, zg_doc_plain(s.doc));
        gtk_box_append(GTK_BOX(labels), name);
        if (fil && body) gtk_box_append(GTK_BOX(labels), small_label("Filament", "dim-label"));
        GtkWidget *editor = part ? zg_setting_editor_new_custom(c->model, &s, region_get, region_set, c) : zg_setting_editor_new(c->model, &s, TRUE);
        gtk_grid_attach(GTK_GRID(c->settings), labels, 0, row, 1, 1);
        gtk_grid_attach(GTK_GRID(c->settings), editor, 2, row, 1, 1);
        if (body && regional) {
            GtkWidget *scope = gtk_button_new_with_label(part ? "This part" : "Whole layers");
            gtk_widget_add_css_class(scope, part ? "suggested-action" : "flat");
            gtk_widget_add_css_class(scope, "zg-scope");
            gtk_widget_set_valign(scope, GTK_ALIGN_CENTER);
            gtk_widget_set_tooltip_text(scope, part ? "The change is for the lit part of these layers only. Click for the whole layers." : "The change is for the whole layers. Click for the lit part only.");
            g_object_set_data_full(G_OBJECT(scope), "zg-name", g_strdup(s.name), g_free);
            g_signal_connect(scope, "clicked", G_CALLBACK(on_scope), c);
            gtk_grid_attach(GTK_GRID(c->settings), scope, 1, row, 1, 1);
        }
        if (s.unit[0] && (s.kind == ZS_SETTING_NUMBER || s.kind == ZS_SETTING_INTEGER)) {
            GtkWidget *unit = gtk_label_new(s.unit);
            gtk_label_set_xalign(GTK_LABEL(unit), 0);
            gtk_widget_add_css_class(unit, "dim-label");
            gtk_widget_add_css_class(unit, "zg-unit");
            gtk_grid_attach(GTK_GRID(c->settings), unit, 3, row, 1, 1);
        }
        char *own = part ? region_get(c, s.name) : NULL;
        if (own) {
            GtkWidget *reset = gtk_button_new_from_icon_name("edit-undo-symbolic");
            gtk_widget_add_css_class(reset, "flat");
            gtk_widget_set_valign(reset, GTK_ALIGN_CENTER);
            gtk_widget_set_tooltip_text(reset, "Remove the change for this part of the layers");
            g_object_set_data_full(G_OBJECT(reset), "zg-name", g_strdup(s.name), g_free);
            g_signal_connect(reset, "clicked", G_CALLBACK(on_region_reset), c);
            gtk_grid_attach(GTK_GRID(c->settings), reset, 4, row, 1, 1);
            g_free(own);
        }
        row++;
        if (body && note && !fil) {
            char *text = g_strdup_printf("Whole layers only. %s", note);
            gtk_grid_attach(GTK_GRID(c->settings), small_label(text, "dim-label"), 0, row++, 5, 1);
            g_free(text);
        }
    }
}

void zg_range_card_show(GtkWidget *card, size_t lo, size_t hi) {
    RangeCard *c = g_object_get_data(G_OBJECT(card), "zg-range-card");
    if (!c) return;
    c->lo = MIN(lo, hi);
    c->hi = MAX(lo, hi);
    double t0, b0, t1, b1;
    if (!layer_z(c, c->lo, &t0, &b0) || !layer_z(c, c->hi, &t1, &b1)) return;
    char *title = c->lo == c->hi ? g_strdup_printf("Layer %zu", c->lo + 1) : g_strdup_printf("Layers %zu–%zu", c->lo + 1, c->hi + 1);
    gtk_label_set_text(GTK_LABEL(c->title), title);
    g_free(title);
    size_t n = c->hi - c->lo + 1;
    char *facts = g_strdup_printf("z %.2f to %.2f mm · %zu %s", b0, t1, n, n == 1 ? "layer" : "layers");
    gtk_label_set_text(GTK_LABEL(c->facts), facts);
    g_free(facts);
    /* The edits are overrides of the layers with a top from t0 to t1, and
     * the editors show the values of the first layer. */
    zg_model_set_scope(c->model, TRUE, t0, t1, t0);
    zg_float_forget(c->card);
    c->open = TRUE;
    c->body_value = 0;
    g_hash_table_remove_all(c->whole);
    gtk_widget_set_visible(c->body_row, zg_view3d_body_lit(zg_preview_view3d(c->preview)));
    c->region = gtk_widget_get_visible(c->body_row) ? zg_view3d_region_find(zg_preview_view3d(c->preview)) : 0;
    body_chips_draw(c);
    fill(c);
    gtk_widget_set_visible(c->card, TRUE);
    place(c);
}

void zg_range_card_close(GtkWidget *card) {
    RangeCard *c = card ? g_object_get_data(G_OBJECT(card), "zg-range-card") : NULL;
    if (!c || !c->open) return;
    c->open = FALSE;
    gtk_widget_set_visible(c->card, FALSE);
    zg_model_set_scope(c->model, FALSE, 0, 0, 0);
    zg_view3d_light_clear(zg_preview_view3d(c->preview));
}

gboolean zg_range_card_open(GtkWidget *card) {
    RangeCard *c = card ? g_object_get_data(G_OBJECT(card), "zg-range-card") : NULL;
    return c && c->open;
}

GtkWidget *zg_range_card_of(GtkWidget *widget) {
    for (GtkWidget *w = widget; w; w = gtk_widget_get_parent(w)) {
        GtkWidget *card = g_object_get_data(G_OBJECT(w), "zg-range-card-of");
        if (card) return card;
    }
    return NULL;
}

static void on_close(GtkButton *b, gpointer data) {
    RangeCard *c = data;
    zg_range_card_close(c->card);
}

static gboolean on_key(GtkEventControllerKey *k, guint key, guint code, GdkModifierType mods, gpointer data) {
    RangeCard *c = data;
    if (key != GDK_KEY_Escape) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(c->card));
    if (focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    zg_range_card_close(c->card);
    gtk_widget_grab_focus(c->preview);
    return TRUE;
}

static void card_free(gpointer data) {
    RangeCard *c = data;
    g_hash_table_unref(c->whole);
    g_object_unref(c->model);
    g_free(c);
}

GtkWidget *zg_range_card_new(ZgModel *model, GtkWidget *preview) {
    RangeCard *c = g_new0(RangeCard, 1);
    c->model = g_object_ref(model);
    c->preview = preview;
    c->whole = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    c->card = zg_card_new();
    gtk_widget_add_css_class(c->card, "zg-range-card");
    gtk_widget_set_size_request(c->card, 300, -1);
    GtkWidget *head;
    c->title = zg_card_head(c->card, &head, NULL, G_CALLBACK(on_close), c);
    gtk_widget_set_tooltip_text(head, "Drag to move the card");
    zg_float_movable(c->card, head, NULL, NULL);
    c->facts = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->facts), 0);
    gtk_widget_add_css_class(c->facts, "dim-label");
    gtk_widget_add_css_class(c->facts, "numeric");
    gtk_box_append(GTK_BOX(c->card), c->facts);
    GtkWidget *note = gtk_label_new("Changes here are for these layers of this print.");
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_widget_add_css_class(note, "caption");
    gtk_box_append(GTK_BOX(c->card), note);
    c->body_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(c->body_row, 4);
    GtkWidget *body_labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(body_labels, TRUE);
    GtkWidget *body_name = gtk_label_new("This part of the layers");
    gtk_label_set_xalign(GTK_LABEL(body_name), 0);
    gtk_label_set_wrap(GTK_LABEL(body_name), TRUE);
    gtk_widget_set_tooltip_text(body_name, "The filament of the lit part of these layers only. The paint of the part keeps it.");
    gtk_box_append(GTK_BOX(body_labels), body_name);
    gtk_box_append(GTK_BOX(body_labels), small_label("Filament", "dim-label"));
    c->body_chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_box_append(GTK_BOX(c->body_row), body_labels);
    gtk_box_append(GTK_BOX(c->body_row), c->body_chips);
    gtk_widget_set_visible(c->body_row, FALSE);
    gtk_box_append(GTK_BOX(c->card), c->body_row);
    c->settings = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(c->settings), 4);
    gtk_grid_set_column_spacing(GTK_GRID(c->settings), 6);
    gtk_widget_set_margin_top(c->settings, 4);
    gtk_box_append(GTK_BOX(c->card), c->settings);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(c->card, keys);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-range-card", c, card_free);
    g_object_set_data(G_OBJECT(preview), "zg-range-card-of", c->card);
    zg_filaments_follow(model, c->card, FALSE, on_filaments_changed);
    zg_view3d_on_frame(zg_preview_view3d(preview), c->card, place, c);
    return c->card;
}
