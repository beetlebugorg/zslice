/* part-card.c: see part-card.h.
 *
 * The card lists the settings of the part from the core: each setting that
 * a part can have (per_part) and that has a value of the part
 * (zg_model_part_setting). The list is made again only when its names
 * change; the editors follow the values themselves.
 *
 * With several parts selected (Shift and a click), the card shows how
 * many, and the actions for all of them: Duplicate, Arrange the plate,
 * To a new plate, and Remove (as web/app/partcard.js). A drag of one of
 * them with the Move tool (or Ctrl), or the arrow keys, moves them all.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "part-card.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "float.h"
#include "label-model.h"
#include "preview.h"
#include "setting-editor.h"
#include "view3d.h"
#include "widgets.h"

typedef struct {
    ZgModel *model;
    GtkWidget *preview, *card, *title, *facts, *settings, *labels, *paint;
    /* The popover of the cut: the height, the flip, and the pegs. */
    GtkWidget *cut_pop, *cut_z, *cut_flip, *cut_pegs, *cut_n, *cut_d;
    GtkWidget *make_n;
    /* The scale in % of the file, and the filament of the part (its chips
     * are for one part: fil_part). */
    GtkWidget *scale, *fil_row;
    gint64 fil_part;
    /* The widgets of one part, and of several parts. */
    GtkWidget *single, *many;
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

/* Grows box by the box of part p on the screen, with the rings of the
 * Turn tool (radius 0.62 of the largest size, and 4 mm): the card covers
 * no part of them. */
static void add_box(PartCard *c, const zs_part *p, double box[4]) {
    double ring = 0.62 * MAX(p->size_x, MAX(p->size_y, p->size_z)) + 4;
    double hx = MAX(p->size_x / 2, ring), hy = MAX(p->size_y / 2, ring), top = MAX(p->size_z, p->size_z / 2 + ring);
    for (int k = 0; k < 8; k++) {
        double qx, qy;
        if (!zg_view3d_pixel_of(zg_preview_view3d(c->preview), p->x + (k & 1 ? hx : -hx), p->y + (k & 2 ? hy : -hy), k & 4 ? top : 0, &qx, &qy))
            continue;
        box[0] = MIN(box[0], qx);
        box[1] = MIN(box[1], qy);
        box[2] = MAX(box[2], qx);
        box[3] = MAX(box[3], qy);
    }
}

/* Next to the part (or the parts), at the right of its top, inside the
 * view; past the rings of the Turn tool, so that the card covers none of
 * them. */
static void place(gpointer data) {
    PartCard *c = data;
    if (!gtk_widget_get_visible(c->card) || zg_float_user_moved(c->card)) return;
    int w = gtk_widget_get_width(c->card), h = gtk_widget_get_height(c->card);
    if (w <= 0) w = 300;
    if (h <= 0) h = 200;
    double box[4] = {INFINITY, INFINITY, -INFINITY, -INFINITY}, area[4], x, y;
    guint n = 0;
    const gint64 *list = zg_model_parts(c->model, &n);
    for (guint i = 0; i < n; i++) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(c->model), (size_t)list[i], &p) == ZS_OK) add_box(c, &p, box);
    }
    zg_free_area(c->preview, area);
    if (box[0] <= box[2]) zg_place_beside(box, area, w, h, &x, &y);
    else {
        x = area[2] - w;
        y = area[1] + 52;
    }
    double ox, oy;
    if (zg_float_get(c->card, &ox, &oy) && fabs(ox - x) < 0.5 && fabs(oy - y) < 0.5) return;
    zg_float_place(c->card, x, y);
}

static void on_clear(GtkButton *b, gpointer data) {
    PartCard *c = data;
    const char *name = g_object_get_data(G_OBJECT(b), "zg-name");
    if (c->part >= 0 && zg_model_part_setting_set(c->model, (size_t)c->part, name, NULL)) zg_model_announce(c->model, name);
}

/* The filament of the part: a chip for each filament of the plate, as on
 * the web. The chips are made again for another part. */
static void fill_filament(PartCard *c) {
    if (c->fil_part == c->part) return;
    c->fil_part = c->part;
    GtkWidget *child = gtk_widget_get_last_child(c->fil_row);
    if (child && child != gtk_widget_get_first_child(c->fil_row)) gtk_box_remove(GTK_BOX(c->fil_row), child);
    for (size_t i = 0; i < zs_setting_count(); i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.name, "project.filament") != 0) continue;
        gtk_widget_set_tooltip_text(gtk_widget_get_first_child(c->fil_row), zg_doc_plain(info.doc));
        gtk_box_append(GTK_BOX(c->fil_row), zg_setting_editor_new_for_part(c->model, &info, (size_t)c->part));
        break;
    }
}

static void on_scale(GtkSpinButton *spin, gpointer data);

/* The scale field follows the part, but not while the user types in it. */
static void update_scale(PartCard *c, const zs_part *p) {
    GtkRoot *root = gtk_widget_get_root(c->scale);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    if (focus && (focus == c->scale || gtk_widget_is_ancestor(focus, c->scale))) return;
    g_signal_handlers_block_by_func(c->scale, on_scale, c);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(c->scale), round(p->scale_x * 10000) / 100);
    g_signal_handlers_unblock_by_func(c->scale, on_scale, c);
}

/* The scale: the same along each axis, in % of the file. */
static void on_scale(GtkSpinButton *spin, gpointer data) {
    PartCard *c = data;
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) return;
    double v = gtk_spin_button_get_value(spin) / 100;
    if (fabs(v - p.scale_x) < 1e-6) return;
    zg_model_part_scale(c->model, (size_t)c->part, v);
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
        gtk_label_set_wrap(GTK_LABEL(label), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_widget_set_tooltip_text(label, zg_doc_plain(info->doc));
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

static void on_label(GtkButton *b, gpointer data) {
    PartCard *c = data;
    if (c->part < 0) return;
    zg_view3d_label_open(zg_preview_view3d(c->preview), c->part, (guint32)GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "zg-label")));
}

/* The labels of the part: a button for each, which selects it in the
 * Label tool. */
static void fill_labels(PartCard *c) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->labels))) gtk_box_remove(GTK_BOX(c->labels), child);
    GPtrArray *list = NULL;
    size_t len = 0;
    zs_app *core = zg_model_core(c->model);
    char small[2048];
    if (c->part >= 0 && zs_app_part_labels_get(core, (size_t)c->part, small, sizeof small, &len) == ZS_OK && len > 2) {
        if (len < sizeof small) list = zg_labels_parse(small, (gssize)len);
        else {
            char *buf = g_malloc(len + 1);
            if (zs_app_part_labels_get(core, (size_t)c->part, buf, len + 1, &len) == ZS_OK) list = zg_labels_parse(buf, (gssize)len);
            g_free(buf);
        }
    }
    gtk_widget_set_visible(c->labels, list && list->len > 0);
    if (list && list->len > 0) {
        GtkWidget *head = gtk_label_new("Labels");
        gtk_widget_add_css_class(head, "zg-card-heading");
        gtk_label_set_xalign(GTK_LABEL(head), 0);
        gtk_box_append(GTK_BOX(c->labels), head);
    }
    for (guint i = 0; list && i < list->len; i++) {
        ZgLabel *l = g_ptr_array_index(list, i);
        char *title = zg_label_title(l);
        char *text = g_strdup_printf("%s · filament %d", title, l->filament);
        GtkWidget *b = gtk_button_new();
        GtkWidget *bl = gtk_label_new(text);
        gtk_label_set_wrap(GTK_LABEL(bl), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(bl), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_xalign(GTK_LABEL(bl), 0);
        gtk_button_set_child(GTK_BUTTON(b), bl);
        gtk_widget_add_css_class(b, "flat");
        gtk_widget_set_tooltip_text(b, "Select this label in the Label tool (E)");
        g_object_set_data(G_OBJECT(b), "zg-label", GUINT_TO_POINTER(l->id));
        g_signal_connect(b, "clicked", G_CALLBACK(on_label), c);
        gtk_box_append(GTK_BOX(c->labels), b);
        g_free(text);
        g_free(title);
    }
    if (list) g_ptr_array_unref(list);
}

static void on_paint(GtkButton *b, gpointer data) {
    PartCard *c = data;
    if (c->part >= 0) zg_model_set_tool(c->model, ZG_TOOL_PAINT);
}

/* The paint of the part: a chip for each filament that it paints with
 * (zs_app_part_paint_used), and a button that opens the Paint tool. */
static void fill_paint(PartCard *c) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->paint))) gtk_box_remove(GTK_BOX(c->paint), child);
    uint32_t used = 0;
    zs_app *core = zg_model_core(c->model);
    if (c->part < 0 || zs_app_part_paint_used(core, (size_t)c->part, &used) != ZS_OK) used = 0;
    /* Bit 0 is the filament of the part: no paint. */
    used &= ~1u;
    gtk_widget_set_visible(c->paint, used != 0);
    if (!used) return;
    GtkWidget *head = gtk_label_new("Paint");
    gtk_widget_add_css_class(head, "zg-card-heading");
    gtk_label_set_xalign(GTK_LABEL(head), 0);
    gtk_box_append(GTK_BOX(c->paint), head);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GString *names = g_string_new(NULL);
    int count = 0;
    for (int k = 1; k < 32; k++) {
        if (!(used & (1u << k))) continue;
        char *color = zg_model_filament_get(c->model, (size_t)(k - 1), "filament.color");
        char num[16];
        g_snprintf(num, sizeof num, "%d", k);
        GtkWidget *chip = zg_filament_chip_new(color && color[0] ? color : NULL, num, FALSE);
        gtk_widget_set_can_target(chip, FALSE);
        gtk_widget_set_focusable(chip, FALSE);
        gtk_box_append(GTK_BOX(row), chip);
        g_string_append_printf(names, "%s%d", count ? ", " : "", k);
        count++;
        g_free(color);
    }
    char *text = g_strdup_printf(count == 1 ? "Painted with filament %s" : "Painted with filaments %s", names->str);
    GtkWidget *l = gtk_label_new(text);
    gtk_widget_add_css_class(l, "dim-label");
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_set_hexpand(l, TRUE);
    gtk_box_append(GTK_BOX(row), l);
    GtkWidget *open = gtk_button_new_with_label("Paint");
    gtk_widget_add_css_class(open, "zg-card-action");
    gtk_widget_set_tooltip_text(open, "Open the Paint tool on this part (P)");
    g_signal_connect(open, "clicked", G_CALLBACK(on_paint), c);
    gtk_box_append(GTK_BOX(row), open);
    gtk_box_append(GTK_BOX(c->paint), row);
    g_free(text);
    g_string_free(names, TRUE);
}

/* The facts of several parts: how many, and their extent on the bed. */
static void update_many(PartCard *c, const gint64 *list, guint n) {
    double box[4] = {INFINITY, INFINITY, -INFINITY, -INFINITY};
    for (guint i = 0; i < n; i++) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(c->model), (size_t)list[i], &p) != ZS_OK) continue;
        box[0] = MIN(box[0], p.x - p.size_x / 2);
        box[1] = MIN(box[1], p.y - p.size_y / 2);
        box[2] = MAX(box[2], p.x + p.size_x / 2);
        box[3] = MAX(box[3], p.y + p.size_y / 2);
    }
    char *title = g_strdup_printf("%u parts", n);
    gtk_label_set_text(GTK_LABEL(c->title), title);
    g_free(title);
    char *text = g_strdup_printf("%.1f × %.1f mm on the bed", box[2] - box[0], box[3] - box[1]);
    gtk_label_set_text(GTK_LABEL(c->facts), text);
    g_free(text);
}

static void refresh(PartCard *c) {
    zs_part p;
    if (c->part < 0 || zs_app_part_get(zg_model_core(c->model), (size_t)c->part, &p) != ZS_OK) {
        gtk_widget_set_visible(c->card, FALSE);
        return;
    }
    guint n = 0;
    const gint64 *list = zg_model_parts(c->model, &n);
    gtk_widget_set_visible(c->single, n <= 1);
    gtk_widget_set_visible(c->many, n > 1);
    if (n > 1) update_many(c, list, n);
    else {
        update_facts(c, &p);
        fill_filament(c);
        update_scale(c, &p);
        fill_settings(c);
        fill_labels(c);
        fill_paint(c);
    }
    place(c);
}

/* The Turn, the Grab, and the Paint tool have no card: the rings, the
 * hand, and the card of the Paint tool are the controls there. */
static gboolean card_wanted(PartCard *c) {
    ZgTool t = zg_model_tool(c->model);
    return c->part >= 0 && t != ZG_TOOL_TURN && t != ZG_TOOL_GRAB && t != ZG_TOOL_PAINT;
}

static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    PartCard *c = data;
    if (part != c->part) {
        /* Another part: the card goes back next to it. */
        zg_float_forget(c->card);
        g_clear_pointer(&c->names, g_free);
    }
    c->part = part;
    gtk_widget_set_visible(c->card, card_wanted(c));
    if (card_wanted(c)) refresh(c);
}

static void on_tool_changed(ZgModel *model, gpointer data) {
    on_part_selected(model, ((PartCard *)data)->part, data);
}

static void on_plate_changed(ZgModel *model, gpointer data) {
    PartCard *c = data;
    if (c->part >= 0 && gtk_widget_get_visible(c->card)) refresh(c);
}

/* A step of the history, an undo, or a redo: the labels and the paint
 * can change. */
static void on_undo_changed(ZgModel *model, gpointer data) {
    PartCard *c = data;
    if (c->part < 0 || !gtk_widget_get_visible(c->card)) return;
    fill_labels(c);
    fill_paint(c);
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

/* Make: copies until there are this many in all. */
static void on_make(GtkButton *b, gpointer data) {
    PartCard *c = data;
    if (c->part < 0) return;
    size_t n = (size_t)gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(c->make_n));
    size_t plates = 0;
    gint64 r = zg_model_part_fill(c->model, (size_t)c->part, n, &plates);
    char *tip = r < 0 ? g_strdup("No copies were made.")
                      : (size_t)r < n ? g_strdup_printf("%d of %d fit: the part is too big for more plates.", (int)r, (int)n)
                                      : g_strdup_printf("%d in all, on %d plates.", (int)r, (int)plates);
    gtk_widget_set_tooltip_text(c->card, tip);
    g_free(tip);
    zg_model_select_part(c->model, -1);
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
    } else if (strcmp(name, "mirror-x") == 0) {
        zg_model_part_mirror(c->model, i, 0);
    } else if (strcmp(name, "mirror-y") == 0) {
        zg_model_part_mirror(c->model, i, 1);
    } else if (strcmp(name, "reset") == 0) {
        zg_model_part_reset(c->model, i);
    } else if (strcmp(name, "remove") == 0) {
        zg_model_part_remove(c->model, i);
    } else if (strcmp(name, "add-setting") == 0) {
        gtk_widget_activate_action_variant(c->card, "win.search-part", g_variant_new_int64(c->part));
    }
}

/* The actions of several parts ("partsmany.*"). */
static void on_many(GSimpleAction *a, GVariant *v, gpointer data) {
    PartCard *c = data;
    const char *name = g_action_get_name(G_ACTION(a));
    if (strcmp(name, "duplicate") == 0) zg_model_parts_duplicate(c->model);
    else if (strcmp(name, "arrange") == 0) zg_model_plate_arrange(c->model);
    else if (strcmp(name, "new-plate") == 0) zg_model_parts_to_new_plate(c->model);
    else if (strcmp(name, "remove") == 0) zg_model_parts_remove(c->model);
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
    /* The card of several parts. */
    c->many = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    static const GActionEntry many_actions[] = {
        {.name = "duplicate", .activate = on_many},
        {.name = "arrange", .activate = on_many},
        {.name = "new-plate", .activate = on_many},
        {.name = "remove", .activate = on_many},
    };
    GSimpleActionGroup *many_group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(many_group), many_actions, G_N_ELEMENTS(many_actions), c);
    gtk_widget_insert_action_group(c->card, "partsmany", G_ACTION_GROUP(many_group));
    g_object_unref(many_group);
    static const struct { const char *label, *action, *tip; } many_buttons[] = {
        {"Duplicate", "partsmany.duplicate", "A copy of each part at a free place on the bed (D)"},
        {"Arrange the plate", "partsmany.arrange", "Put all parts of the plate in rows, apart from each other"},
        {"To a new plate", "partsmany.new-plate", "Move these parts to one new plate, with the settings of this plate"},
        {"Remove", "partsmany.remove", "Remove these parts from the plate (Delete). Ctrl+Z brings them back."},
    };
    GtkWidget *many_flow = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(many_flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(many_flow), 3);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(many_flow), 4);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(many_flow), 4);
    for (size_t i = 0; i < G_N_ELEMENTS(many_buttons); i++) {
        GtkWidget *b = gtk_button_new_with_label(many_buttons[i].label);
        gtk_actionable_set_action_name(GTK_ACTIONABLE(b), many_buttons[i].action);
        gtk_widget_set_tooltip_text(b, many_buttons[i].tip);
        gtk_widget_add_css_class(b, "zg-card-action");
        if (strcmp(many_buttons[i].label, "Remove") == 0) gtk_widget_add_css_class(b, "destructive-action");
        gtk_flow_box_append(GTK_FLOW_BOX(many_flow), b);
    }
    gtk_box_append(GTK_BOX(c->many), many_flow);
    GtkWidget *hint = gtk_label_new("To move them all: drag one of them with the Move tool (or Ctrl and a drag), or press the arrow keys.");
    gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(hint), 40);
    gtk_label_set_xalign(GTK_LABEL(hint), 0);
    gtk_widget_add_css_class(hint, "dim-label");
    gtk_box_append(GTK_BOX(c->many), hint);
    gtk_widget_set_visible(c->many, FALSE);
    gtk_box_append(GTK_BOX(c->card), c->many);
    /* The card of one part. */
    c->single = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(c->card), c->single);
    c->fil_part = -1;
    c->fil_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *fil_label = gtk_label_new("Filament");
    gtk_label_set_xalign(GTK_LABEL(fil_label), 0);
    gtk_widget_set_hexpand(fil_label, TRUE);
    gtk_box_append(GTK_BOX(c->fil_row), fil_label);
    gtk_box_append(GTK_BOX(c->single), c->fil_row);
    static const GActionEntry actions[] = {
        {.name = "duplicate", .activate = on_action},
        {.name = "split", .activate = on_action},
        {.name = "new-plate", .activate = on_action},
        {.name = "smart", .activate = on_action},
        {.name = "less-support", .activate = on_action},
        {.name = "mirror-x", .activate = on_action},
        {.name = "mirror-y", .activate = on_action},
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
        {"Mirror X", "partcard.mirror-x", "Mirror the part from left to right"},
        {"Mirror Y", "partcard.mirror-y", "Mirror the part from front to back"},
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
    gtk_box_append(GTK_BOX(c->single), flow);
    /* The scale, in % of the file (Enter applies). */
    GtkWidget *scale_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(scale_row), gtk_label_new("Scale"));
    c->scale = gtk_spin_button_new_with_range(1, 100000, 1);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(c->scale), 1);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(c->scale), 100);
    gtk_widget_set_tooltip_text(c->scale, "The size of the part, in % of the file (Enter applies)");
    g_signal_connect(c->scale, "value-changed", G_CALLBACK(on_scale), c);
    gtk_box_append(GTK_BOX(scale_row), c->scale);
    GtkWidget *percent = gtk_label_new("%");
    gtk_widget_add_css_class(percent, "dim-label");
    gtk_box_append(GTK_BOX(scale_row), percent);
    gtk_box_append(GTK_BOX(c->single), scale_row);
    GtkWidget *make = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(make), gtk_label_new("Make"));
    c->make_n = gtk_spin_button_new_with_range(2, 10000, 1);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(c->make_n), 10);
    gtk_box_append(GTK_BOX(make), c->make_n);
    GtkWidget *in_all = gtk_label_new("in all");
    gtk_widget_add_css_class(in_all, "dim-label");
    gtk_box_append(GTK_BOX(make), in_all);
    GtkWidget *make_b = gtk_button_new_with_label("Make");
    gtk_widget_set_tooltip_text(make_b, "Copies of the part until there are this many in all: on this plate while they fit, then on new plates with the same settings");
    gtk_widget_add_css_class(make_b, "zg-card-action");
    g_signal_connect(make_b, "clicked", G_CALLBACK(on_make), c);
    gtk_box_append(GTK_BOX(make), make_b);
    gtk_box_append(GTK_BOX(c->single), make);
    c->settings = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(c->settings), 4);
    gtk_grid_set_column_spacing(GTK_GRID(c->settings), 6);
    gtk_widget_set_margin_top(c->settings, 4);
    gtk_widget_set_visible(c->settings, FALSE);
    gtk_box_append(GTK_BOX(c->single), c->settings);
    c->labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_visible(c->labels, FALSE);
    gtk_box_append(GTK_BOX(c->single), c->labels);
    c->paint = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_visible(c->paint, FALSE);
    gtk_box_append(GTK_BOX(c->single), c->paint);
    GtkWidget *add = gtk_button_new_with_label("+ Add a setting for this part");
    gtk_widget_add_css_class(add, "flat");
    gtk_widget_set_halign(add, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(add, "Search the settings that a part can have of its own");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(add), "partcard.add-setting");
    gtk_box_append(GTK_BOX(c->single), add);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(c->card, keys);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-part-card", c, card_free);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), c);
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed), c);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plate_changed), c);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_undo_changed), c);
    zg_view3d_on_frame(zg_preview_view3d(preview), c->card, place, c);
    return c->card;
}
