/* part-card.c: see part-card.h.
 *
 * The card lists the settings of the part from the core: each setting that
 * a part can have (per_part) and that has a value of the part
 * (zg_model_part_setting). The list is made again only when its names
 * change; the editors follow the values themselves.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "part-card.h"

#include <math.h>
#include <string.h>

#include "float.h"
#include "preview.h"
#include "setting-editor.h"
#include "view3d.h"

typedef struct {
    ZgModel *model;
    GtkWidget *preview, *card, *title, *facts, *settings;
    /* The popover of the cut: the height, the flip, and the pegs. */
    GtkWidget *cut_pop, *cut_z, *cut_flip, *cut_pegs, *cut_n, *cut_d;
    gint64 part;
    char *names; /* the names of the listed settings, one a line */
} PartCard;

static void update_facts(PartCard *c, const zs_part *p) {
    gtk_label_set_text(GTK_LABEL(c->title), p->name && p->name[0] ? p->name : "Part");
    int turn = ((int)lround(p->rotation) % 360 + 360) % 360;
    char *text = turn ? g_strdup_printf("%.1f × %.1f × %.1f mm · turned %d°", p->size_x, p->size_y, p->size_z, turn)
                      : g_strdup_printf("%.1f × %.1f × %.1f mm", p->size_x, p->size_y, p->size_z);
    gtk_label_set_text(GTK_LABEL(c->facts), text);
    g_free(text);
}

/* Next to the part, at the right of its top, inside the view; past the
 * rings of the Turn tool, so that the card covers none of them. */
static void place(gpointer data) {
    PartCard *c = data;
    if (!gtk_widget_get_visible(c->card) || zg_float_user_moved(c->card)) return;
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) return;
    int W = gtk_widget_get_width(c->preview), H = gtk_widget_get_height(c->preview);
    int w = gtk_widget_get_width(c->card), h = gtk_widget_get_height(c->card);
    if (w <= 0) w = 300;
    if (h <= 0) h = 200;
    double ring = 0.62 * MAX(p.size_x, MAX(p.size_y, p.size_z)) + 4;
    double qx, qy;
    gboolean at = zg_view3d_pixel_of(zg_preview_view3d(c->preview), p.x + MAX(p.size_x / 2, ring) + 6, p.y, p.size_z / 2, &qx, &qy);
    double x = at ? qx + 24 : W - w - 70, y = at ? qy - h / 2.0 : 80;
    if (x + w > W - 60) x = (at ? qx : W) - w - 24;
    x = CLAMP(x, 62, MAX(62, W - w - 8));
    y = CLAMP(y, 60, MAX(60, H - h - 140));
    double ox, oy;
    if (zg_float_get(c->card, &ox, &oy) && fabs(ox - x) < 0.5 && fabs(oy - y) < 0.5) return;
    zg_float_place(c->card, x, y);
}

static void on_clear(GtkButton *b, gpointer data) {
    PartCard *c = data;
    const char *name = g_object_get_data(G_OBJECT(b), "zg-name");
    if (c->part >= 0 && zg_model_part_setting_set(c->model, (size_t)c->part, name, NULL)) zg_model_announce(c->model, name);
}

/* The settings of the part: a row for each, with its editor and x. */
static void fill_settings(PartCard *c) {
    GString *names = g_string_new(NULL);
    GPtrArray *infos = g_ptr_array_new_with_free_func(g_free);
    for (size_t i = 0; c->part >= 0 && i < zs_setting_count(); i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK || !info.per_part) continue;
        char *own = zg_model_part_setting(c->model, (size_t)c->part, info.name);
        if (!own) continue;
        g_free(own);
        g_string_append_printf(names, "%s\n", info.name);
        g_ptr_array_add(infos, g_memdup2(&info, sizeof info));
    }
    if (g_strcmp0(names->str, c->names) == 0) {
        g_string_free(names, TRUE);
        g_ptr_array_free(infos, TRUE);
        return;
    }
    g_free(c->names);
    c->names = g_string_free(names, FALSE);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->settings))) gtk_grid_remove(GTK_GRID(c->settings), child);
    gtk_widget_set_visible(c->settings, infos->len > 0);
    if (infos->len > 0) {
        GtkWidget *head = gtk_label_new("Settings of this part");
        gtk_widget_add_css_class(head, "zg-card-heading");
        gtk_label_set_xalign(GTK_LABEL(head), 0);
        gtk_grid_attach(GTK_GRID(c->settings), head, 0, 0, 3, 1);
    }
    for (guint i = 0; i < infos->len; i++) {
        const zs_setting_info *info = g_ptr_array_index(infos, i);
        GtkWidget *label = gtk_label_new(info->label);
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_widget_set_tooltip_text(label, info->doc);
        GtkWidget *editor = zg_setting_editor_new_for_part(c->model, info, (size_t)c->part);
        GtkWidget *clear = gtk_button_new_from_icon_name("window-close-symbolic");
        gtk_widget_add_css_class(clear, "flat");
        gtk_widget_add_css_class(clear, "zg-card-close");
        gtk_widget_set_valign(clear, GTK_ALIGN_CENTER);
        char *tip = g_strdup_printf("%s: the value of the plate again", info->label);
        gtk_widget_set_tooltip_text(clear, tip);
        g_free(tip);
        g_object_set_data_full(G_OBJECT(clear), "zg-name", g_strdup(info->name), g_free);
        g_signal_connect(clear, "clicked", G_CALLBACK(on_clear), c);
        gtk_grid_attach(GTK_GRID(c->settings), label, 0, (int)i + 1, 1, 1);
        gtk_grid_attach(GTK_GRID(c->settings), editor, 1, (int)i + 1, 1, 1);
        gtk_grid_attach(GTK_GRID(c->settings), clear, 2, (int)i + 1, 1, 1);
    }
    g_ptr_array_free(infos, TRUE);
}

static void refresh(PartCard *c) {
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) {
        gtk_widget_set_visible(c->card, FALSE);
        return;
    }
    update_facts(c, &p);
    fill_settings(c);
    place(c);
}

static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    PartCard *c = data;
    if (part != c->part) {
        /* Another part: the card goes back next to it. */
        zg_float_forget(c->card);
        g_clear_pointer(&c->names, g_free);
    }
    c->part = part;
    gtk_widget_set_visible(c->card, part >= 0);
    if (part >= 0) refresh(c);
}

static void on_plate_changed(ZgModel *model, gpointer data) {
    PartCard *c = data;
    if (c->part >= 0 && gtk_widget_get_visible(c->card)) refresh(c);
}

/* ---- the cut ---- */

/* The plane of the cut in the view, at the height of the scale. */
static void show_cut(PartCard *c) {
    GtkWidget *v3 = zg_preview_view3d(c->preview);
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) {
        zg_view3d_set_cut(v3, 0, 0, 0, 0, 0);
        return;
    }
    double z = gtk_range_get_value(GTK_RANGE(c->cut_z));
    zg_view3d_set_cut(v3, p.x - p.size_x / 2 - 3, p.y - p.size_y / 2 - 3, p.x + p.size_x / 2 + 3, p.y + p.size_y / 2 + 3, z);
}

static void on_cut_z(GtkRange *r, gpointer data) {
    show_cut(data);
}

static void on_cut_shown(GtkPopover *pop, gpointer data) {
    PartCard *c = data;
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) return;
    gtk_range_set_range(GTK_RANGE(c->cut_z), 0.2, MAX(0.4, p.size_z - 0.2));
    gtk_range_set_value(GTK_RANGE(c->cut_z), round(p.size_z / 2 * 10) / 10);
    show_cut(c);
}

static void on_cut_hidden(GtkPopover *pop, gpointer data) {
    PartCard *c = data;
    zg_view3d_set_cut(zg_preview_view3d(c->preview), 0, 0, 0, 0, 0);
}

static void on_cut_go(GtkButton *b, gpointer data) {
    PartCard *c = data;
    if (c->part < 0) return;
    size_t i = (size_t)c->part;
    int pegs = gtk_check_button_get_active(GTK_CHECK_BUTTON(c->cut_pegs)) ? gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(c->cut_n)) : 0;
    gint64 n = zg_model_part_cut(c->model, i, gtk_range_get_value(GTK_RANGE(c->cut_z)), gtk_check_button_get_active(GTK_CHECK_BUTTON(c->cut_flip)), pegs,
                                 gtk_spin_button_get_value(GTK_SPIN_BUTTON(c->cut_d)));
    gtk_popover_popdown(GTK_POPOVER(c->cut_pop));
    if (n <= 0) {
        gtk_widget_set_tooltip_text(c->card, "The plane does not cut the part.");
        return;
    }
    char *tip = n > 2 ? g_strdup_printf("Cut into two parts, with %d pegs. Glue the pegs into the holes to join the parts.", (int)(n - 2))
                      : g_strdup(pegs > 0 ? "Cut into two parts. No peg fits: the cut is too small or too thin for one." : "Cut into two parts.");
    gtk_widget_set_tooltip_text(c->card, tip);
    g_free(tip);
    zg_model_select_part(c->model, (gint64)i);
}

/* The Cut… button: a popover with the height (the plane follows in the
 * view), the flip of the top, the pegs, and Cut. */
static GtkWidget *cut_button(PartCard *c) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(box, 8);
    gtk_widget_set_margin_end(box, 8);
    gtk_widget_set_margin_top(box, 8);
    gtk_widget_set_margin_bottom(box, 8);
    GtkWidget *hrow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(hrow), gtk_label_new("Height (mm)"));
    c->cut_z = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.2, 10, 0.1);
    gtk_scale_set_draw_value(GTK_SCALE(c->cut_z), TRUE);
    gtk_scale_set_digits(GTK_SCALE(c->cut_z), 1);
    gtk_widget_set_hexpand(c->cut_z, TRUE);
    gtk_widget_set_size_request(c->cut_z, 200, -1);
    g_signal_connect(c->cut_z, "value-changed", G_CALLBACK(on_cut_z), c);
    gtk_box_append(GTK_BOX(hrow), c->cut_z);
    gtk_box_append(GTK_BOX(box), hrow);
    c->cut_flip = gtk_check_button_new_with_label("Turn the top over (it prints on its cut face)");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c->cut_flip), TRUE);
    gtk_box_append(GTK_BOX(box), c->cut_flip);
    GtkWidget *prow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    c->cut_pegs = gtk_check_button_new_with_label("Pegs to line up the parts:");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c->cut_pegs), TRUE);
    gtk_widget_set_tooltip_text(c->cut_pegs, "Holes in both cut faces, and pegs that print as parts of their own. Glue the pegs into the holes: the parts line up. A peg goes only where the part is wide and deep enough.");
    c->cut_n = gtk_spin_button_new_with_range(1, 4, 1);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(c->cut_n), 2);
    c->cut_d = gtk_spin_button_new_with_range(2, 20, 0.5);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(c->cut_d), 5);
    gtk_box_append(GTK_BOX(prow), c->cut_pegs);
    gtk_box_append(GTK_BOX(prow), c->cut_n);
    gtk_box_append(GTK_BOX(prow), gtk_label_new("of"));
    gtk_box_append(GTK_BOX(prow), c->cut_d);
    gtk_box_append(GTK_BOX(prow), gtk_label_new("mm"));
    gtk_box_append(GTK_BOX(box), prow);
    GtkWidget *go = gtk_button_new_with_label("Cut");
    gtk_widget_add_css_class(go, "suggested-action");
    gtk_widget_set_halign(go, GTK_ALIGN_END);
    g_signal_connect(go, "clicked", G_CALLBACK(on_cut_go), c);
    gtk_box_append(GTK_BOX(box), go);
    c->cut_pop = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(c->cut_pop), box);
    g_signal_connect(c->cut_pop, "show", G_CALLBACK(on_cut_shown), c);
    g_signal_connect(c->cut_pop, "closed", G_CALLBACK(on_cut_hidden), c);
    GtkWidget *mb = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(mb), "Cut…");
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(mb), c->cut_pop);
    gtk_widget_set_tooltip_text(mb, "Cut the part in two with a level plane");
    gtk_widget_add_css_class(mb, "zg-card-action");
    return mb;
}

/* The actions of the card ("partcard.*"). */
static void on_action(GSimpleAction *a, GVariant *v, gpointer data) {
    PartCard *c = data;
    if (c->part < 0) return;
    size_t i = (size_t)c->part;
    const char *name = g_action_get_name(G_ACTION(a));
    if (strcmp(name, "duplicate") == 0) {
        gint64 copy = zg_model_part_duplicate(c->model, i);
        if (copy >= 0) zg_model_select_part(c->model, copy);
    } else if (strcmp(name, "new-plate") == 0) {
        zg_model_part_to_new_plate(c->model, i);
    } else if (strcmp(name, "split") == 0) {
        gint64 n = zg_model_part_split(c->model, i);
        if (n == 0) gtk_widget_set_tooltip_text(c->card, "The part has one body: nothing to split.");
        else if (n > 0) zg_model_select_part(c->model, (gint64)i);
    } else if (strcmp(name, "smart") == 0) {
        zg_model_part_place(c->model, i, ZS_PLACE_SMART, 0);
    } else if (strcmp(name, "less-support") == 0) {
        zg_model_part_place(c->model, i, ZS_PLACE_LESS_SUPPORT, 0);
    } else if (strcmp(name, "reset") == 0) {
        zg_model_part_reset(c->model, i);
    } else if (strcmp(name, "remove") == 0) {
        zg_model_part_remove(c->model, i);
    } else if (strcmp(name, "add-setting") == 0) {
        gtk_widget_activate_action_variant(c->card, "win.search-part", g_variant_new_int64(c->part));
    }
}

static void on_close(GtkButton *b, gpointer data) {
    PartCard *c = data;
    zg_model_select_part(c->model, -1);
}

static gboolean on_key(GtkEventControllerKey *k, guint key, guint code, GdkModifierType mods, gpointer data) {
    PartCard *c = data;
    if (key != GDK_KEY_Escape) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(c->card));
    if (focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    zg_model_select_part(c->model, -1);
    gtk_widget_grab_focus(c->preview);
    return TRUE;
}

static void card_free(gpointer data) {
    PartCard *c = data;
    g_signal_handlers_disconnect_by_data(c->model, c);
    g_free(c->names);
    g_object_unref(c->model);
    g_free(c);
}

GtkWidget *zg_part_card_new(ZgModel *model, GtkWidget *preview) {
    PartCard *c = g_new0(PartCard, 1);
    c->model = g_object_ref(model);
    c->preview = preview;
    c->part = -1;
    c->card = zg_card_new();
    gtk_widget_add_css_class(c->card, "zg-part-card");
    gtk_widget_set_size_request(c->card, 290, -1);
    GtkWidget *head;
    c->title = zg_card_head(c->card, &head, NULL, G_CALLBACK(on_close), c);
    gtk_widget_set_tooltip_text(head, "Drag to move the card");
    zg_float_movable(c->card, head, NULL, NULL);
    c->facts = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(c->facts), 0);
    gtk_widget_add_css_class(c->facts, "dim-label");
    gtk_widget_add_css_class(c->facts, "numeric");
    gtk_box_append(GTK_BOX(c->card), c->facts);
    static const GActionEntry actions[] = {
        {.name = "duplicate", .activate = on_action},
        {.name = "split", .activate = on_action},
        {.name = "new-plate", .activate = on_action},
        {.name = "smart", .activate = on_action},
        {.name = "less-support", .activate = on_action},
        {.name = "reset", .activate = on_action},
        {.name = "remove", .activate = on_action},
        {.name = "add-setting", .activate = on_action},
    };
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), actions, G_N_ELEMENTS(actions), c);
    gtk_widget_insert_action_group(c->card, "partcard", G_ACTION_GROUP(group));
    g_object_unref(group);
    static const struct { const char *label, *action, *tip; } buttons[] = {
        {"Duplicate", "partcard.duplicate", "A copy of the part at a free place on the bed (D)"},
        {"Split to parts", "partcard.split", "Make each separate body of the part a part of its own, at its place"},
        {"Best orientation", "partcard.smart", "Turn the part to its best orientation: less support, more on the bed, low"},
        {"Less support", "partcard.less-support", "Turn the part to need the least support"},
        {"Reset", "partcard.reset", "The orientation and the scale of the file again"},
        {"To a new plate", "partcard.new-plate", "Move the part to a new plate, with the settings of this plate"},
        {"Remove", "partcard.remove", "Remove the part from the plate (Delete). Ctrl+Z brings it back."},
    };
    GtkWidget *flow = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 3);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow), 4);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow), 4);
    for (size_t i = 0; i < G_N_ELEMENTS(buttons); i++) {
        GtkWidget *b = gtk_button_new_with_label(buttons[i].label);
        gtk_actionable_set_action_name(GTK_ACTIONABLE(b), buttons[i].action);
        gtk_widget_set_tooltip_text(b, buttons[i].tip);
        gtk_widget_add_css_class(b, "zg-card-action");
        if (strcmp(buttons[i].label, "Remove") == 0) gtk_widget_add_css_class(b, "destructive-action");
        gtk_flow_box_append(GTK_FLOW_BOX(flow), b);
        if (strcmp(buttons[i].label, "Split to parts") == 0) gtk_flow_box_append(GTK_FLOW_BOX(flow), cut_button(c));
    }
    gtk_box_append(GTK_BOX(c->card), flow);
    c->settings = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(c->settings), 4);
    gtk_grid_set_column_spacing(GTK_GRID(c->settings), 6);
    gtk_widget_set_margin_top(c->settings, 4);
    gtk_widget_set_visible(c->settings, FALSE);
    gtk_box_append(GTK_BOX(c->card), c->settings);
    GtkWidget *add = gtk_button_new_with_label("+ Add a setting for this part");
    gtk_widget_add_css_class(add, "flat");
    gtk_widget_set_halign(add, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(add, "Search the settings that a part can have of its own");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(add), "partcard.add-setting");
    gtk_box_append(GTK_BOX(c->card), add);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(c->card, keys);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-part-card", c, card_free);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), c);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plate_changed), c);
    zg_view3d_on_frame(zg_preview_view3d(preview), c->card, place, c);
    return c->card;
}
