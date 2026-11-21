/* paint-card.c: see paint-card.h.
 *
 * The chips are made again only when the list of filaments, the chosen
 * filament, or the filament of the part changes. The work waits for the
 * main loop: a click on a chip changes the chips, and a chip must not go
 * in its own click.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "paint-card.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "float.h"

typedef struct {
    ZgModel *model;
    ZgPaintTool *tool;
    GtkWidget *card, *smart, *brush, *size_row, *size, *size_text, *chips, *hint, *notice;
    char *chips_key;
    guint idle;
    gboolean updating;
} PaintCard;

static PaintCard *card_of(GtkWidget *card) {
    return g_object_get_data(G_OBJECT(card), "zg-paint-card");
}

static const char *hint_of(ZgPaintMode mode) {
    return mode == ZG_PAINT_SMART
               ? "Click a raised letter, a logo, or a face to paint it. Shift and a click add more. A right drag turns the view."
               : "Drag over the surface to paint it. A right drag turns the view.";
}

static void on_mode(GtkToggleButton *b, gpointer data) {
    PaintCard *c = data;
    if (c->updating || !gtk_toggle_button_get_active(b)) return;
    zg_paint_tool_set_mode(c->tool, GTK_WIDGET(b) == c->brush ? ZG_PAINT_BRUSH : ZG_PAINT_SMART);
}

static void on_size(GtkRange *r, gpointer data) {
    PaintCard *c = data;
    if (c->updating) return;
    zg_paint_tool_set_size(c->tool, gtk_range_get_value(r));
    char *text = g_strdup_printf("%.1f mm", zg_paint_tool_size(c->tool));
    gtk_label_set_text(GTK_LABEL(c->size_text), text);
    g_free(text);
}

static void on_chip(GtkButton *b, gpointer data) {
    PaintCard *c = data;
    zg_paint_tool_set_filament(c->tool, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-filament")));
}

static void on_add_filament(GtkButton *b, gpointer data) {
    zg_paint_tool_add_filament(((PaintCard *)data)->tool);
}

static void on_clear(GtkButton *b, gpointer data) {
    zg_paint_tool_clear(((PaintCard *)data)->tool);
}

static void on_close(GtkButton *b, gpointer data) {
    PaintCard *c = data;
    zg_model_set_tool(c->model, ZG_TOOL_SELECT);
}

/* The chips of the filaments, made again when they change. */
static void draw_chips(PaintCard *c) {
    size_t n = zs_app_filament_count(zg_model_core(c->model));
    int chosen = zg_paint_tool_filament(c->tool), base = zg_paint_tool_base(c->tool);
    GString *key = g_string_new(NULL);
    g_string_append_printf(key, "%d %d", chosen, base);
    for (size_t i = 0; i < n; i++) {
        char *color = zg_model_filament_get(c->model, i, "filament.color");
        char *mat = zg_model_filament_get(c->model, i, "filament.material");
        g_string_append_printf(key, " %s %s", color ? color : "", mat ? mat : "");
        g_free(color);
        g_free(mat);
    }
    if (c->chips_key && strcmp(c->chips_key, key->str) == 0) {
        g_string_free(key, TRUE);
        return;
    }
    g_free(c->chips_key);
    c->chips_key = g_string_free(key, FALSE);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->chips))) gtk_flow_box_remove(GTK_FLOW_BOX(c->chips), child);
    for (size_t i = 0; i < n; i++) {
        char *color = zg_model_filament_get(c->model, i, "filament.color");
        char *mat = zg_model_filament_get(c->model, i, "filament.material");
        char num[16];
        g_snprintf(num, sizeof num, "%zu", i + 1);
        GtkWidget *chip = zg_filament_chip_new(color, num, (int)i + 1 == chosen);
        char *tip = g_strdup_printf("Paint with filament %zu (%s, %s)%s", i + 1, mat && mat[0] ? mat : "filament", color ? color : "",
                                    (int)i + 1 == base ? ": the filament of the part" : "");
        gtk_widget_set_tooltip_text(chip, tip);
        gtk_widget_set_focus_on_click(chip, FALSE);
        g_object_set_data(G_OBJECT(chip), "zg-filament", GINT_TO_POINTER((int)i + 1));
        g_signal_connect(chip, "clicked", G_CALLBACK(on_chip), c);
        gtk_flow_box_append(GTK_FLOW_BOX(c->chips), chip);
        g_free(tip);
        g_free(mat);
        g_free(color);
    }
    GtkWidget *plus = zg_filament_chip_new(NULL, "+", FALSE);
    gtk_widget_set_tooltip_text(plus, "Add a filament to the plate");
    gtk_widget_set_focus_on_click(plus, FALSE);
    g_signal_connect(plus, "clicked", G_CALLBACK(on_add_filament), c);
    gtk_flow_box_append(GTK_FLOW_BOX(c->chips), plus);
    /* No other filament: the paint does not show. */
    gtk_widget_set_visible(c->notice, n <= 1);
}

static void update(PaintCard *c) {
    c->updating = TRUE;
    ZgPaintMode mode = zg_paint_tool_mode(c->tool);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(mode == ZG_PAINT_BRUSH ? c->brush : c->smart), TRUE);
    gtk_widget_set_visible(c->size_row, mode == ZG_PAINT_BRUSH);
    double size = zg_paint_tool_size(c->tool);
    if (fabs(gtk_range_get_value(GTK_RANGE(c->size)) - size) > 1e-9) gtk_range_set_value(GTK_RANGE(c->size), size);
    char *text = g_strdup_printf("%.1f mm", size);
    gtk_label_set_text(GTK_LABEL(c->size_text), text);
    g_free(text);
    gtk_label_set_text(GTK_LABEL(c->hint), hint_of(mode));
    draw_chips(c);
    c->updating = FALSE;
}

static gboolean on_idle(gpointer data) {
    PaintCard *c = data;
    c->idle = 0;
    update(c);
    return G_SOURCE_REMOVE;
}

void zg_paint_card_update(GtkWidget *card) {
    PaintCard *c = card_of(card);
    if (!c->idle) c->idle = g_idle_add(on_idle, c);
}

static GtkWidget *dim_label(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD);
    gtk_label_set_max_width_chars(GTK_LABEL(l), 36);
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

static void card_free(gpointer data) {
    PaintCard *c = data;
    if (c->idle) g_source_remove(c->idle);
    g_free(c->chips_key);
    g_free(c);
}

GtkWidget *zg_paint_card_new(ZgModel *model, ZgPaintTool *tool) {
    PaintCard *c = g_new0(PaintCard, 1);
    c->model = model;
    c->tool = tool;
    c->card = zg_card_new();
    gtk_widget_add_css_class(c->card, "zg-paint-card");
    gtk_widget_set_halign(c->card, GTK_ALIGN_START);
    gtk_widget_set_valign(c->card, GTK_ALIGN_START);
    gtk_widget_set_margin_start(c->card, 64);
    gtk_widget_set_margin_top(c->card, 10);
    gtk_widget_set_size_request(c->card, 280, -1);
    GtkWidget *title = zg_card_head(c->card, NULL, NULL, G_CALLBACK(on_close), c);
    gtk_label_set_text(GTK_LABEL(title), "Paint");
    /* The mode. */
    GtkWidget *modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(modes, "linked");
    c->smart = gtk_toggle_button_new_with_label("Smart select");
    c->brush = gtk_toggle_button_new_with_label("Brush");
    gtk_widget_set_tooltip_text(c->smart, "Click a region: a raised letter, a logo, or a face. Shift and a click add regions.");
    gtk_widget_set_tooltip_text(c->brush, "Drag over the surface to paint it.");
    gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(c->brush), GTK_TOGGLE_BUTTON(c->smart));
    for (GtkWidget **b = (GtkWidget *[]){c->smart, c->brush, NULL}; *b; b++) {
        gtk_widget_set_focus_on_click(*b, FALSE);
        gtk_widget_set_hexpand(*b, TRUE);
        g_signal_connect(*b, "toggled", G_CALLBACK(on_mode), c);
        gtk_box_append(GTK_BOX(modes), *b);
    }
    gtk_box_append(GTK_BOX(c->card), modes);
    /* The size of the brush. */
    c->size_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(c->size_row), dim_label("Size", NULL));
    c->size = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.3, 10, 0.1);
    gtk_scale_set_draw_value(GTK_SCALE(c->size), FALSE);
    gtk_widget_set_hexpand(c->size, TRUE);
    gtk_widget_set_focus_on_click(c->size, FALSE);
    gtk_widget_set_tooltip_text(c->size, "The radius of the brush");
    g_signal_connect(c->size, "value-changed", G_CALLBACK(on_size), c);
    gtk_box_append(GTK_BOX(c->size_row), c->size);
    c->size_text = gtk_label_new("");
    gtk_widget_add_css_class(c->size_text, "dim-label");
    gtk_widget_add_css_class(c->size_text, "numeric");
    gtk_label_set_width_chars(GTK_LABEL(c->size_text), 7);
    gtk_label_set_xalign(GTK_LABEL(c->size_text), 1);
    gtk_box_append(GTK_BOX(c->size_row), c->size_text);
    gtk_box_append(GTK_BOX(c->card), c->size_row);
    /* The filaments. */
    GtkWidget *head = gtk_label_new("Filament");
    gtk_widget_add_css_class(head, "zg-card-heading");
    gtk_label_set_xalign(GTK_LABEL(head), 0);
    gtk_box_append(GTK_BOX(c->card), head);
    c->chips = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(c->chips), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(c->chips), 9);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(c->chips), 4);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(c->chips), 4);
    gtk_box_append(GTK_BOX(c->card), c->chips);
    c->notice = dim_label("The plate has one filament. Add a filament (+) to paint with it.", "zg-note");
    gtk_widget_set_visible(c->notice, FALSE);
    gtk_box_append(GTK_BOX(c->card), c->notice);
    c->hint = dim_label(hint_of(ZG_PAINT_SMART), "dim-label");
    gtk_widget_add_css_class(c->hint, "caption");
    gtk_box_append(GTK_BOX(c->card), c->hint);
    GtkWidget *clear = gtk_button_new_with_label("Remove all paint");
    gtk_widget_set_tooltip_text(clear, "The whole part prints with its own filament again");
    gtk_widget_set_focus_on_click(clear, FALSE);
    gtk_widget_set_halign(clear, GTK_ALIGN_START);
    gtk_widget_add_css_class(clear, "zg-card-action");
    g_signal_connect(clear, "clicked", G_CALLBACK(on_clear), c);
    gtk_box_append(GTK_BOX(c->card), clear);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-paint-card", c, card_free);
    update(c);
    return c->card;
}
