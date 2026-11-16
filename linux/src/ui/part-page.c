/* part-page.c: see part-page.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "part-page.h"

#include "widgets.h"

#include <string.h>

typedef struct {
    ZgModel *model;
    GtkWidget *title, *size, *x, *y, *rot, *scale;
    gboolean filling;
} PartPage;

static void part_fill(PartPage *pp) {
    gint64 i = zg_model_selected_part(pp->model);
    zs_part p;
    if (i < 0 || zs_app_part_get(zg_model_core(pp->model), (size_t)i, &p) != ZS_OK) return;
    pp->filling = TRUE;
    gtk_label_set_text(GTK_LABEL(pp->title), p.name);
    char *size = g_strdup_printf("%.1f × %.1f × %.1f mm", p.size_x, p.size_y, p.size_z);
    gtk_label_set_text(GTK_LABEL(pp->size), size);
    g_free(size);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(pp->x), p.x);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(pp->y), p.y);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(pp->rot), p.rotation);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(pp->scale), p.scale_x * 100);
    pp->filling = FALSE;
}

static void on_part_value(GtkSpinButton *spin, gpointer data) {
    PartPage *pp = data;
    gint64 i = zg_model_selected_part(pp->model);
    if (pp->filling || i < 0) return;
    if (GTK_WIDGET(spin) == pp->rot) {
        zg_model_part_rotate(pp->model, (size_t)i, gtk_spin_button_get_value(spin));
    } else if (GTK_WIDGET(spin) == pp->scale) {
        zg_model_part_scale(pp->model, (size_t)i, gtk_spin_button_get_value(spin) / 100);
    } else {
        zg_model_part_move(pp->model, (size_t)i, gtk_spin_button_get_value(GTK_SPIN_BUTTON(pp->x)),
                           gtk_spin_button_get_value(GTK_SPIN_BUTTON(pp->y)));
    }
}

static void on_part_turn(GtkButton *b, gpointer data) {
    PartPage *pp = data;
    gint64 i = zg_model_selected_part(pp->model);
    if (i >= 0) zg_model_part_rotate(pp->model, (size_t)i, gtk_spin_button_get_value(GTK_SPIN_BUTTON(pp->rot)) + 90);
}

static void on_part_remove(GtkButton *b, gpointer data) {
    PartPage *pp = data;
    gint64 i = zg_model_selected_part(pp->model);
    if (i >= 0) zg_model_part_remove(pp->model, (size_t)i);
}

static void on_part_arrange(GtkButton *b, gpointer data) {
    PartPage *pp = data;
    zg_model_plate_arrange(pp->model);
}

/* The placement actions of the part page ("part.*"). */
static void on_part_action(GSimpleAction *a, GVariant *v, gpointer data) {
    PartPage *pp = data;
    gint64 i = zg_model_selected_part(pp->model);
    if (i < 0) return;
    const char *name = g_action_get_name(G_ACTION(a));
    if (strcmp(name, "smart") == 0) zg_model_part_place(pp->model, (size_t)i, ZS_PLACE_SMART, 0);
    else if (strcmp(name, "less-support") == 0) zg_model_part_place(pp->model, (size_t)i, ZS_PLACE_LESS_SUPPORT, 0);
    else if (strcmp(name, "strength") == 0) zg_model_part_place(pp->model, (size_t)i, ZS_PLACE_STRENGTH, g_variant_get_int32(v));
    else if (strcmp(name, "turn") == 0) zg_model_part_turn(pp->model, (size_t)i, g_variant_get_int32(v), 90);
    else if (strcmp(name, "reset") == 0) zg_model_part_reset(pp->model, (size_t)i);
}

static void on_part_plate_changed(ZgModel *model, gpointer data) {
    PartPage *pp = g_object_get_data(G_OBJECT(data), "zg-part-page");
    if (pp) part_fill(pp);
}

static GtkWidget *part_spin(PartPage *pp, double lo, double hi, double step) {
    GtkWidget *s = gtk_spin_button_new_with_range(lo, hi, step);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(s), 1);
    g_signal_connect(s, "value-changed", G_CALLBACK(on_part_value), pp);
    return s;
}

GtkWidget *zg_part_page_new(ZgModel *model) {
    PartPage *pp = g_new0(PartPage, 1);
    pp->model = model;
    GtkWidget *grid = zg_grid_new();
    int row = 0;
    pp->title = zg_grid_add_heading(grid, &row, "");
    gtk_widget_add_css_class(pp->title, "zg-insp-title");
    pp->size = zg_wrapped_label_new("");
    gtk_widget_add_css_class(pp->size, "dim-label");
    gtk_grid_attach(GTK_GRID(grid), pp->size, 0, row++, 4, 1);
    const char *names[] = {"X (center)", "Y (center)", "Turn", "Scale"};
    const char *units[] = {"mm", "mm", "°", "%"};
    pp->x = part_spin(pp, -1000, 3000, 1);
    pp->y = part_spin(pp, -1000, 3000, 1);
    pp->rot = part_spin(pp, -720, 720, 15);
    pp->scale = part_spin(pp, 1, 1000, 5);
    GtkWidget *spins[] = {pp->x, pp->y, pp->rot, pp->scale};
    for (int k = 0; k < 4; k++) {
        GtkWidget *l = gtk_label_new(names[k]);
        gtk_label_set_xalign(GTK_LABEL(l), 0);
        gtk_widget_set_hexpand(l, TRUE);
        GtkWidget *u = gtk_label_new(units[k]);
        gtk_widget_add_css_class(u, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), l, 0, row, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), spins[k], 1, row, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), u, 2, row++, 1, 1);
    }
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(buttons, 8);
    GtkWidget *turn = gtk_button_new_with_label("Turn 90°");
    g_signal_connect(turn, "clicked", G_CALLBACK(on_part_turn), pp);
    GtkWidget *arrange = gtk_button_new_with_label("Arrange the plate");
    g_signal_connect(arrange, "clicked", G_CALLBACK(on_part_arrange), pp);
    GtkWidget *remove = gtk_button_new_with_label("Remove");
    gtk_widget_add_css_class(remove, "destructive-action");
    g_signal_connect(remove, "clicked", G_CALLBACK(on_part_remove), pp);
    gtk_box_append(GTK_BOX(buttons), turn);
    gtk_box_append(GTK_BOX(buttons), arrange);
    gtk_box_append(GTK_BOX(buttons), remove);
    gtk_grid_attach(GTK_GRID(grid), buttons, 0, row++, 4, 1);

    /* Placement: the smart placement first; then the other modes. */
    static const GActionEntry part_actions[] = {
        {.name = "smart", .activate = on_part_action},
        {.name = "less-support", .activate = on_part_action},
        {.name = "strength", .activate = on_part_action, .parameter_type = "i"},
        {.name = "turn", .activate = on_part_action, .parameter_type = "i"},
        {.name = "reset", .activate = on_part_action},
    };
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), part_actions, G_N_ELEMENTS(part_actions), pp);
    gtk_widget_insert_action_group(grid, "part", G_ACTION_GROUP(group));
    g_object_unref(group);
    GtkWidget *place_head = zg_grid_add_heading(grid, &row, "Placement");
    gtk_widget_set_margin_top(place_head, 12);
    GtkWidget *place = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *smart = gtk_button_new_with_label("Smart placement");
    gtk_widget_add_css_class(smart, "suggested-action");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(smart), "part.smart");
    gtk_widget_set_hexpand(smart, FALSE);
    gtk_widget_set_tooltip_text(smart, "Turns the part for the least support, the most area on the bed, and a low height.");
    GtkWidget *less = gtk_button_new_with_label("Less support");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(less), "part.less-support");
    gtk_widget_set_tooltip_text(less, "Turns the part for the least support only.");
    GMenu *axes = g_menu_new();
    g_menu_append(axes, "Along X of the part", "part.strength(0)");
    g_menu_append(axes, "Along Y of the part", "part.strength(1)");
    g_menu_append(axes, "Along Z of the part", "part.strength(2)");
    GtkWidget *strong = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(strong), "Strong along");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(strong), G_MENU_MODEL(axes));
    gtk_widget_set_tooltip_text(strong, "Which way does the load go (the axes of the file)? The part turns so that this axis lies in the layers (a print is weakest across its layers), with the least support.");
    g_object_unref(axes);
    gtk_box_append(GTK_BOX(place), smart);
    gtk_box_append(GTK_BOX(place), less);
    gtk_box_append(GTK_BOX(place), strong);
    gtk_grid_attach(GTK_GRID(grid), place, 0, row++, 4, 1);
    GtkWidget *turns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    const char *turn_labels[] = {"Turn 90° about X", "Turn 90° about Y", "Reset"};
    const char *turn_actions[] = {"part.turn(0)", "part.turn(1)", "part.reset"};
    for (int k = 0; k < 3; k++) {
        GtkWidget *bt = gtk_button_new_with_label(turn_labels[k]);
        gtk_actionable_set_detailed_action_name(GTK_ACTIONABLE(bt), turn_actions[k]);
        gtk_box_append(GTK_BOX(turns), bt);
    }
    gtk_widget_set_tooltip_text(turns, "Reset: the orientation and the size of the file.");
    gtk_grid_attach(GTK_GRID(grid), turns, 0, row++, 4, 1);
    GtkWidget *hint = zg_wrapped_label_new("Ctrl+drag the part in the 3D view to move it, and Ctrl+wheel to turn it. Click a line to see its settings.");
    gtk_widget_add_css_class(hint, "dim-label");
    gtk_widget_set_margin_top(hint, 8);
    gtk_grid_attach(GTK_GRID(grid), hint, 0, row++, 4, 1);
    g_object_set_data_full(G_OBJECT(grid), "zg-part-page", pp, g_free);
    /* The handler goes away with the page (the grid). */
    g_signal_connect_object(model, "plate-changed", G_CALLBACK(on_part_plate_changed), grid, G_CONNECT_DEFAULT);
    part_fill(pp);
    return grid;
}
