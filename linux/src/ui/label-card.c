/* label-card.c: see label-card.h.
 *
 * The card builds its fields again only when the shapes of the label
 * change (another label, another shape, another item, or a free line that
 * starts or stops to draw); else it gives the same fields the new values,
 * and the field with the focus keeps the text that the user types. The
 * work waits for the main loop: a click on a chip changes the label, and
 * the new chips must not replace the chip in its own click.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "label-card.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "float.h"

/* A field that follows the label: an item and a field of it ("at:0" and
 * "at:1" for the offset, "turn", "depth", "relief"). */
typedef struct {
    GtkWidget *widget;
    int item;
    char *field;
} Input;

typedef struct {
    ZgModel *model;
    ZgLabelTool *tool;
    GtkWidget *card, *title, *scroll, *notice, *notice_text, *notice_add, *curve_note;
    GtkWidget *items, *add, *svg, *turn, *chips, *depth1, *depth2, *depth_mm, *check, *cost;
    GtkWidget *mode[ZG_LABEL_MODES], *relief_row;
    /* The label that the card shows (a copy), and the key of its fields. */
    ZgLabel *label;
    char *key;
    GPtrArray *inputs; /* Input */
    guint idle;
    gboolean updating, focus_text;
} LabelCard;

static void input_free(gpointer data) {
    Input *in = data;
    g_free(in->field);
    g_free(in);
}

static LabelCard *card_of(GtkWidget *card) {
    return g_object_get_data(G_OBJECT(card), "zg-label-card");
}

/* The widget of the preview (it has the keys of the view). */
static GtkWidget *preview_of(GtkWidget *w) {
    for (; w; w = gtk_widget_get_parent(w))
        if (g_object_get_data(G_OBJECT(w), "zg-preview")) return w;
    return NULL;
}

static GtkWidget *dim_label(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD);
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

static GtkWidget *heading(const char *text) {
    GtkWidget *h = gtk_label_new(text);
    gtk_widget_add_css_class(h, "zg-card-heading");
    gtk_label_set_xalign(GTK_LABEL(h), 0);
    return h;
}

static int digits_of(double step) {
    return step >= 1 ? 0 : step >= 0.1 ? 1 : 2;
}

static GtkWidget *spin(double value, double min, double max, double step) {
    GtkWidget *s = gtk_spin_button_new_with_range(min, max, step);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(s), (guint)digits_of(step));
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(s), value);
    gtk_spin_button_set_numeric(GTK_SPIN_BUTTON(s), FALSE);
    gtk_editable_set_width_chars(GTK_EDITABLE(s), 5);
    gtk_widget_add_css_class(s, "zg-label-num");
    return s;
}

/* The number in a spin button as typed, or NAN. */
static double typed(GtkWidget *s) {
    const char *text = gtk_editable_get_text(GTK_EDITABLE(s));
    char *end = NULL;
    char *dot = g_strdelimit(g_strdup(text), ",", '.');
    double v = g_ascii_strtod(dot, &end);
    gboolean ok = end && end != dot && *g_strchug(end) == '\0';
    g_free(dot);
    return ok && isfinite(v) ? v : NAN;
}

static Input *add_input(LabelCard *c, GtkWidget *w, int item, const char *field) {
    Input *in = g_new0(Input, 1);
    in->widget = w;
    in->item = item;
    in->field = g_strdup(field);
    g_ptr_array_add(c->inputs, in);
    return in;
}

static double item_at(JsonObject *it, int k) {
    if (!it || !json_object_has_member(it, "at")) return 0;
    JsonArray *a = json_object_get_array_member(it, "at");
    return a && json_array_get_length(a) == 2 ? json_array_get_double_element(a, (guint)k) : 0;
}

/* The value of an input in label l. */
static double input_value(const ZgLabel *l, const Input *in) {
    if (strcmp(in->field, "turn") == 0) return round(zg_label_angle(l) * 10) / 10;
    if (strcmp(in->field, "depth") == 0) return l->depth;
    if (strcmp(in->field, "relief") == 0) return l->relief > 0 ? l->relief : ZG_LABEL_DEFAULT_RELIEF;
    JsonObject *it = zg_label_item(l, (guint)MAX(in->item, 0));
    if (strcmp(in->field, "at:0") == 0) return item_at(it, 0);
    if (strcmp(in->field, "at:1") == 0) return item_at(it, 1);
    return zg_label_item_number(it, in->field, 0);
}

/* ---- the edits ---- */

static void on_number(GtkEditable *e, gpointer data) {
    LabelCard *c = data;
    if (c->updating) return;
    Input *in = g_object_get_data(G_OBJECT(e), "zg-input");
    GtkWidget *w = GTK_WIDGET(e);
    double v = typed(w), min = 0, max = 0;
    gtk_spin_button_get_range(GTK_SPIN_BUTTON(w), &min, &max);
    gboolean ok = !isnan(v) && v >= min && v <= max;
    if (ok) {
        if (strcmp(in->field, "turn") == 0) zg_label_tool_set_angle(c->tool, v);
        else if (strcmp(in->field, "depth") == 0) zg_label_tool_set_depth(c->tool, v);
        else if (strcmp(in->field, "relief") == 0) zg_label_tool_set_relief(c->tool, v);
        else if (strncmp(in->field, "at:", 3) == 0) {
            const ZgLabel *l = zg_label_tool_label(c->tool);
            JsonObject *it = l ? zg_label_item(l, (guint)in->item) : NULL;
            double x = in->field[3] == '0' ? v : item_at(it, 0), y = in->field[3] == '1' ? v : item_at(it, 1);
            ok = zg_label_tool_edit_at(c->tool, (guint)in->item, x, y);
        } else {
            ok = zg_label_tool_edit_number(c->tool, (guint)in->item, in->field, v);
        }
    }
    if (ok) gtk_widget_remove_css_class(w, "error");
    else gtk_widget_add_css_class(w, "error");
}

static void on_text(GtkEditable *e, gpointer data) {
    LabelCard *c = data;
    if (c->updating) return;
    Input *in = g_object_get_data(G_OBJECT(e), "zg-input");
    zg_label_tool_edit_text(c->tool, (guint)in->item, gtk_editable_get_text(e));
}

static void on_flag(GtkCheckButton *b, gpointer data) {
    LabelCard *c = data;
    if (c->updating) return;
    Input *in = g_object_get_data(G_OBJECT(b), "zg-input");
    if (!zg_label_tool_edit_flag(c->tool, (guint)in->item, in->field, gtk_check_button_get_active(b))) {
        c->updating = TRUE;
        gtk_check_button_set_active(b, !gtk_check_button_get_active(b));
        c->updating = FALSE;
    }
}

static void on_shape(GtkToggleButton *b, gpointer data) {
    LabelCard *c = data;
    if (c->updating || !gtk_toggle_button_get_active(b)) return;
    int item = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-item"));
    zg_label_tool_set_shape(c->tool, (guint)item, g_object_get_data(G_OBJECT(b), "zg-kind"));
}

static void on_remove_item(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    zg_label_tool_remove_item(c->tool, (guint)GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-item")));
}

static void on_draw(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    int item = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-item"));
    zg_label_tool_draw_points(c->tool, zg_label_tool_drawing(c->tool) == item ? -1 : item);
}

static void on_add(GObject *dd, GParamSpec *pspec, gpointer data) {
    LabelCard *c = data;
    guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (c->updating || i == 0 || i == GTK_INVALID_LIST_POSITION || i > ZG_LABEL_KINDS) return;
    c->updating = TRUE;
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), 0);
    c->updating = FALSE;
    zg_label_tool_add_item(c->tool, zg_label_kinds[i - 1]);
}

static void on_depth_lines(GtkToggleButton *b, gpointer data) {
    LabelCard *c = data;
    if (c->updating) return;
    JsonObject *info = zg_label_tool_info(c->tool);
    double lw = info ? json_object_get_double_member_with_default(info, "line_width", 0.42) : 0.42;
    zg_label_tool_set_depth(c->tool, b == GTK_TOGGLE_BUTTON(c->depth1) ? 0 : 2 * lw);
}

static void on_mode(GtkToggleButton *b, gpointer data) {
    LabelCard *c = data;
    if (c->updating || !gtk_toggle_button_get_active(b)) return;
    zg_label_tool_set_mode(c->tool, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-mode")));
}

static void on_svg_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    LabelCard *c = data;
    GFile *f = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (!f) return;
    char *text = NULL;
    char *path = g_file_get_path(f);
    if (g_file_load_contents(f, NULL, &text, NULL, NULL, NULL)) zg_label_tool_place_svg(c->tool, text, path);
    g_free(text);
    g_free(path);
    g_object_unref(f);
}

/* "Place an SVG…": a file dialog for an SVG file. */
static void on_svg(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, "Place an SVG");
    GtkFileFilter *f = gtk_file_filter_new();
    gtk_file_filter_set_name(f, "SVG pictures");
    gtk_file_filter_add_suffix(f, "svg");
    gtk_file_filter_add_mime_type(f, "image/svg+xml");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, f);
    gtk_file_dialog_set_filters(d, G_LIST_MODEL(filters));
    GtkRoot *root = gtk_widget_get_root(c->card);
    gtk_file_dialog_open(d, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, on_svg_chosen, c);
    g_object_unref(filters);
    g_object_unref(f);
    g_object_unref(d);
}

static void on_chip(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    zg_label_tool_set_filament(c->tool, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-filament")));
}

static void on_add_filament(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    zg_label_tool_add_filament(c->tool);
}

static void on_delete(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    zg_label_tool_remove(c->tool);
}

static void on_close(GtkButton *b, gpointer data) {
    LabelCard *c = data;
    zg_label_tool_select(c->tool, -1);
}

/* Esc: in a field, the keys go back to the view; else the card closes
 * (the label stays). */
static gboolean on_key(GtkEventControllerKey *k, guint key, guint code, GdkModifierType mods, gpointer data) {
    LabelCard *c = data;
    if (key != GDK_KEY_Escape) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(c->card));
    if (focus && gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER)) return FALSE;
    GtkWidget *preview = preview_of(c->card);
    gboolean in_field = focus && (GTK_IS_EDITABLE(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_EDITABLE));
    if (!in_field) zg_label_tool_select(c->tool, -1);
    if (preview) gtk_widget_grab_focus(preview);
    return TRUE;
}

/* ---- the fields of one shape ---- */

static GtkWidget *item_box(LabelCard *c, const ZgLabel *l, guint i) {
    JsonObject *it = zg_label_item(l, i);
    const char *kind = zg_label_item_kind(it);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(box, "zg-label-item");
    GtkWidget *chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(row, "linked");
    gtk_widget_set_hexpand(row, TRUE);
    GtkWidget *first = NULL;
    if (strcmp(kind, "svg") == 0) {
        /* An SVG picture: its chip, and the chips to make it another
         * shape. */
        first = gtk_toggle_button_new_with_label("SVG");
        gtk_widget_add_css_class(first, "zg-label-chip");
        gtk_widget_set_hexpand(first, TRUE);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(first), TRUE);
        gtk_widget_set_tooltip_text(first, "An SVG picture");
        gtk_box_append(GTK_BOX(row), first);
    }
    for (int k = 0; k < ZG_LABEL_KINDS; k++) {
        GtkWidget *b = gtk_toggle_button_new_with_label(zg_label_kind_names[k]);
        gtk_widget_add_css_class(b, "zg-label-chip");
        gtk_widget_set_hexpand(b, TRUE);
        if (first) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(b), GTK_TOGGLE_BUTTON(first));
        else first = b;
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(b), strcmp(kind, zg_label_kinds[k]) == 0);
        char *tip = strcmp(zg_label_kinds[k], "polyline") == 0 ? g_strdup("A free line: click points on the face")
                                                                : g_strdup_printf("Make this shape a %s", zg_label_kinds[k]);
        gtk_widget_set_tooltip_text(b, tip);
        g_free(tip);
        g_object_set_data(G_OBJECT(b), "zg-item", GINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(b), "zg-kind", (gpointer)zg_label_kinds[k]);
        g_signal_connect(b, "toggled", G_CALLBACK(on_shape), c);
        gtk_box_append(GTK_BOX(row), b);
    }
    gtk_box_append(GTK_BOX(chips), row);
    if (zg_label_item_count(l) > 1) {
        GtkWidget *x = gtk_button_new_from_icon_name("window-close-symbolic");
        gtk_widget_add_css_class(x, "flat");
        gtk_widget_add_css_class(x, "zg-card-close");
        gtk_widget_set_valign(x, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text(x, "Remove this shape from the label");
        g_object_set_data(G_OBJECT(x), "zg-item", GINT_TO_POINTER(i));
        g_signal_connect(x, "clicked", G_CALLBACK(on_remove_item), c);
        gtk_box_append(GTK_BOX(chips), x);
    }
    gtk_box_append(GTK_BOX(box), chips);
    if (strcmp(kind, "text") == 0) {
        GtkWidget *t = gtk_entry_new();
        gtk_entry_set_max_length(GTK_ENTRY(t), 256);
        gtk_entry_set_placeholder_text(GTK_ENTRY(t), "Text");
        gtk_widget_add_css_class(t, "zg-label-text");
        gtk_widget_set_tooltip_text(t, "The text of the label");
        const char *text = json_object_has_member(it, "text") ? json_object_get_string_member(it, "text") : "";
        gtk_editable_set_text(GTK_EDITABLE(t), text ? text : "");
        g_object_set_data(G_OBJECT(t), "zg-input", add_input(c, t, (int)i, "text"));
        g_signal_connect(t, "changed", G_CALLBACK(on_text), c);
        gtk_box_append(GTK_BOX(box), t);
    }
    /* The number fields, one to a row: a name never breaks inside a
     * word. */
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 4);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 6);
    size_t n = 0;
    const ZgLabelField *f = zg_label_fields(kind, &n);
    for (size_t k = 0; k < n; k++) {
        GtkWidget *name = dim_label(f[k].name, NULL);
        gtk_widget_set_hexpand(name, TRUE);
        gtk_widget_set_tooltip_text(name, f[k].tip ? f[k].tip : f[k].name);
        GtkWidget *s = spin(zg_label_item_number(it, f[k].field, 0), f[k].min, f[k].max, f[k].step);
        gtk_widget_set_tooltip_text(s, f[k].tip ? f[k].tip : f[k].name);
        g_object_set_data(G_OBJECT(s), "zg-input", add_input(c, s, (int)i, f[k].field));
        g_signal_connect(s, "changed", G_CALLBACK(on_number), c);
        GtkWidget *unit = gtk_label_new(f[k].unit);
        gtk_widget_add_css_class(unit, "dim-label");
        gtk_grid_attach(GTK_GRID(grid), name, 0, (int)k, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), s, 1, (int)k, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), unit, 2, (int)k, 1, 1);
    }
    gtk_box_append(GTK_BOX(box), grid);
    if (strcmp(kind, "polyline") == 0) {
        GtkWidget *flags = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
        static const char *const names[2][2] = {{"closed", "Closed"}, {"filled", "Filled"}};
        for (int k = 0; k < 2; k++) {
            GtkWidget *b = gtk_check_button_new_with_label(names[k][1]);
            gtk_check_button_set_active(GTK_CHECK_BUTTON(b), json_object_get_boolean_member_with_default(it, names[k][0], FALSE));
            g_object_set_data(G_OBJECT(b), "zg-input", add_input(c, b, (int)i, names[k][0]));
            g_signal_connect(b, "toggled", G_CALLBACK(on_flag), c);
            gtk_box_append(GTK_BOX(flags), b);
        }
        gtk_box_append(GTK_BOX(box), flags);
        gboolean drawing = zg_label_tool_drawing(c->tool) == (int)i;
        GtkWidget *draw = gtk_button_new_with_label(drawing ? "Done" : "Draw points");
        gtk_widget_set_tooltip_text(draw, drawing ? "Stop: the line keeps its points" : "Click points on the face, one after the other");
        gtk_widget_add_css_class(draw, "zg-card-action");
        gtk_widget_set_halign(draw, GTK_ALIGN_START);
        g_object_set_data(G_OBJECT(draw), "zg-item", GINT_TO_POINTER(i));
        g_signal_connect(draw, "clicked", G_CALLBACK(on_draw), c);
        gtk_box_append(GTK_BOX(box), draw);
        if (drawing) gtk_box_append(GTK_BOX(box), dim_label("Click points on the face. Click Done at the end.", "dim-label"));
    }
    /* The place of the shape in the label. */
    GtkWidget *at = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *name = dim_label("Offset", NULL);
    gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(at), name);
    for (int k = 0; k < 2; k++) {
        GtkWidget *s = spin(item_at(it, k), -500, 500, 0.1);
        gtk_widget_set_tooltip_text(s, k == 0 ? "Right of the center of the label, mm" : "Up from the center of the label, mm");
        g_object_set_data(G_OBJECT(s), "zg-input", add_input(c, s, (int)i, k == 0 ? "at:0" : "at:1"));
        g_signal_connect(s, "changed", G_CALLBACK(on_number), c);
        gtk_box_append(GTK_BOX(at), s);
    }
    GtkWidget *mm = gtk_label_new("mm");
    gtk_widget_add_css_class(mm, "dim-label");
    gtk_box_append(GTK_BOX(at), mm);
    gtk_box_append(GTK_BOX(box), at);
    return box;
}

/* The shapes of a label and the item that draws: a card with another key
 * has other fields. */
static char *key_of(LabelCard *c, const ZgLabel *l) {
    GString *k = g_string_new(NULL);
    g_string_append_printf(k, "%u:%d:", l->id, zg_label_tool_drawing(c->tool));
    for (guint i = 0; i < zg_label_item_count(l); i++) g_string_append_printf(k, "%s,", zg_label_item_kind(zg_label_item(l, i)));
    return g_string_free(k, FALSE);
}

static void build_items(LabelCard *c, const ZgLabel *l) {
    /* The inputs of the items go; turn, relief, and depth stay (the first
     * three). */
    while (c->inputs->len > 3) g_ptr_array_remove_index(c->inputs, c->inputs->len - 1);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->items))) gtk_box_remove(GTK_BOX(c->items), child);
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        if (i > 0) gtk_box_append(GTK_BOX(c->items), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
        gtk_box_append(GTK_BOX(c->items), item_box(c, l, i));
    }
}

/* ---- the filaments ---- */

static void draw_chips(LabelCard *c, const ZgLabel *l) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->chips))) gtk_flow_box_remove(GTK_FLOW_BOX(c->chips), child);
    size_t n = zs_app_filament_count(zg_model_core(c->model));
    int base = zg_label_tool_base(c->tool);
    for (size_t i = 0; i < n; i++) {
        char *color = zg_model_filament_get(c->model, i, "filament.color");
        char *mat = zg_model_filament_get(c->model, i, "filament.material");
        char num[16];
        g_snprintf(num, sizeof num, "%zu", i + 1);
        GtkWidget *chip = zg_filament_chip_new(color, num, (int)i + 1 == l->filament);
        char *tip = g_strdup_printf("Filament %zu (%s, %s)%s", i + 1, mat[0] ? mat : "filament", color, (int)i + 1 == base ? ": the filament of the part" : "");
        gtk_widget_set_tooltip_text(chip, tip);
        g_object_set_data(G_OBJECT(chip), "zg-filament", GINT_TO_POINTER((int)i + 1));
        g_signal_connect(chip, "clicked", G_CALLBACK(on_chip), c);
        gtk_flow_box_append(GTK_FLOW_BOX(c->chips), chip);
        g_free(tip);
        g_free(mat);
        g_free(color);
    }
    GtkWidget *plus = zg_filament_chip_new(NULL, "+", FALSE);
    gtk_widget_set_tooltip_text(plus, "Add a filament to the plate, for this label");
    g_signal_connect(plus, "clicked", G_CALLBACK(on_add_filament), c);
    gtk_flow_box_append(GTK_FLOW_BOX(c->chips), plus);
    /* An ink label in the filament of the part does not show. */
    gboolean same = l->filament == base && l->mode == ZG_LABEL_INK;
    gtk_widget_set_visible(c->notice, same);
    gtk_widget_set_visible(c->notice_add, same && n <= 1);
    gtk_label_set_text(GTK_LABEL(c->notice_text), n <= 1 ? "The plate has one filament, so this label does not show."
                                                         : "The label has the filament of the part, so it does not show. Pick another filament.");
}

/* ---- the values ---- */

static void update(LabelCard *c, const ZgLabel *l) {
    char *title = zg_label_title(l);
    char *text = g_strdup_printf("Label %s", title);
    gtk_label_set_text(GTK_LABEL(c->title), text);
    g_free(text);
    g_free(title);
    c->updating = TRUE;
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(c->card));
    for (guint i = 0; i < c->inputs->len; i++) {
        Input *in = g_ptr_array_index(c->inputs, i);
        /* The field with the focus keeps what the user types. */
        if (focus && (focus == in->widget || gtk_widget_is_ancestor(focus, in->widget))) continue;
        if (GTK_IS_SPIN_BUTTON(in->widget)) {
            double v = input_value(l, in);
            if (fabs(gtk_spin_button_get_value(GTK_SPIN_BUTTON(in->widget)) - v) > 1e-9 || !isfinite(typed(in->widget)))
                gtk_spin_button_set_value(GTK_SPIN_BUTTON(in->widget), v);
            gtk_widget_remove_css_class(in->widget, "error");
        } else if (GTK_IS_CHECK_BUTTON(in->widget)) {
            JsonObject *it = zg_label_item(l, (guint)in->item);
            gtk_check_button_set_active(GTK_CHECK_BUTTON(in->widget), it && json_object_get_boolean_member_with_default(it, in->field, FALSE));
        } else if (GTK_IS_EDITABLE(in->widget)) {
            JsonObject *it = zg_label_item(l, (guint)in->item);
            const char *t = it && json_object_has_member(it, "text") ? json_object_get_string_member(it, "text") : "";
            if (g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(in->widget)), t ? t : "") != 0) gtk_editable_set_text(GTK_EDITABLE(in->widget), t ? t : "");
        }
    }
    JsonObject *info = zg_label_tool_info(c->tool);
    double lw = info ? json_object_get_double_member_with_default(info, "line_width", 0.42) : 0.42;
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->depth1), !(l->depth > 0));
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->depth2), fabs(l->depth - 2 * lw) < 1e-6);
    for (int k = 0; k < ZG_LABEL_MODES; k++) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->mode[k]), l->mode == k);
    gtk_widget_set_visible(c->relief_row, l->mode != ZG_LABEL_INK);
    c->updating = FALSE;
    draw_chips(c, l);
}

static void apply(LabelCard *c) {
    const ZgLabel *l = c->label;
    if (!l) {
        gtk_widget_set_visible(c->card, FALSE);
        g_clear_pointer(&c->key, g_free);
        zg_float_forget(c->card);
        return;
    }
    char *key = key_of(c, l);
    gboolean other = g_strcmp0(key, c->key) != 0;
    /* Another label: the card goes back beside it. */
    if (!c->key || strtoul(c->key, NULL, 10) != l->id) zg_float_forget(c->card);
    if (other) {
        g_free(c->key);
        c->key = key;
        c->updating = TRUE;
        build_items(c, l);
        c->updating = FALSE;
    } else {
        g_free(key);
    }
    update(c, l);
    zg_label_card_curve(c->card, zg_label_tool_curve(c->tool));
    zg_label_card_info(c->card, zg_label_tool_info(c->tool));
    gtk_widget_set_visible(c->card, TRUE);
    if (c->focus_text) {
        c->focus_text = FALSE;
        for (guint i = 0; i < c->inputs->len; i++) {
            Input *in = g_ptr_array_index(c->inputs, i);
            if (strcmp(in->field, "text") != 0) continue;
            gtk_widget_grab_focus(in->widget);
            gtk_editable_select_region(GTK_EDITABLE(in->widget), 0, -1);
            break;
        }
    }
}

static gboolean on_idle(gpointer data) {
    LabelCard *c = data;
    c->idle = 0;
    apply(c);
    return G_SOURCE_REMOVE;
}

void zg_label_card_show(GtkWidget *card, const ZgLabel *l) {
    LabelCard *c = card_of(card);
    zg_label_free(c->label);
    c->label = l ? zg_label_copy(l) : NULL;
    if (!l) {
        /* Hidden at once: no card of a label that went. */
        if (c->idle) g_source_remove(c->idle);
        c->idle = 0;
        apply(c);
        return;
    }
    if (!c->idle) c->idle = g_idle_add(on_idle, c);
}

void zg_label_card_focus_text(GtkWidget *card) {
    LabelCard *c = card_of(card);
    c->focus_text = TRUE;
    if (!c->idle) c->idle = g_idle_add(on_idle, c);
}

void zg_label_card_curve(GtkWidget *card, double deg) {
    LabelCard *c = card_of(card);
    gtk_widget_set_visible(c->curve_note, deg > ZG_LABEL_CURVE_LIMIT);
}

/* A row of the facts: a name and a value. */
static void fact(GtkWidget *grid, int row, const char *k, const char *v, gboolean warn) {
    GtkWidget *kl = dim_label(k, "dim-label");
    GtkWidget *vl = dim_label(v, "zg-stat-value");
    gtk_widget_set_hexpand(vl, TRUE);
    if (warn) gtk_widget_add_css_class(vl, "warning");
    gtk_grid_attach(GTK_GRID(grid), kl, 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), vl, 1, row, 1, 1);
}

static GtkWidget *facts_grid(void) {
    GtkWidget *g = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(g), 10);
    gtk_grid_set_row_spacing(GTK_GRID(g), 2);
    return g;
}

static double num(JsonObject *o, const char *k) {
    return json_object_get_double_member_with_default(o, k, 0);
}

void zg_label_card_info(GtkWidget *card, JsonObject *info) {
    LabelCard *c = card_of(card);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(c->check))) gtk_box_remove(GTK_BOX(c->check), child);
    while ((child = gtk_widget_get_first_child(c->cost))) gtk_box_remove(GTK_BOX(c->cost), child);
    if (!info) return;
    double lw = json_object_get_double_member_with_default(info, "line_width", 0.42);
    GtkWidget *stats = facts_grid();
    int row = 0;
    char *v;
    if (num(info, "thinnest") > 0) {
        v = g_strdup_printf("%.2f mm", num(info, "thinnest"));
        fact(stats, row++, "Thinnest stroke", v, num(info, "thinnest") < 2 * lw);
        g_free(v);
    }
    if (num(info, "clean_size") > 0) {
        v = g_strdup_printf("clean from %.1f mm, fair from %.1f mm", num(info, "clean_size"), num(info, "fair_size"));
        fact(stats, row++, "Text size", v, FALSE);
        g_free(v);
    }
    gtk_box_append(GTK_BOX(c->check), stats);
    const char *advice = json_object_get_string_member_with_default(info, "advice", "");
    if (advice && advice[0]) gtk_box_append(GTK_BOX(c->check), dim_label(advice, "zg-explain"));
    if (json_object_get_boolean_member_with_default(info, "same_filament", FALSE)) return;
    gboolean sliced = json_object_get_boolean_member_with_default(info, "sliced", FALSE);
    int n = (int)lround(num(info, sliced ? "changes" : "estimate_changes"));
    GtkWidget *cost = facts_grid();
    row = 0;
    v = g_strdup_printf("%d filament %s", n, n == 1 ? "change" : "changes");
    fact(cost, row++, sliced ? "Adds" : "Adds about", v, FALSE);
    g_free(v);
    v = g_strdup_printf("%ld min", lround(num(info, "minutes")));
    fact(cost, row++, "Time", v, FALSE);
    g_free(v);
    v = g_strdup_printf("%.1f g", num(info, "grams"));
    fact(cost, row++, "Flush", v, FALSE);
    g_free(v);
    if (num(info, "layers") > 0) {
        v = g_strdup_printf("%ld (%.1f to %.1f mm)", lround(num(info, "layers")), num(info, "z_min"), num(info, "z_max"));
        fact(cost, row++, "Layers", v, FALSE);
        g_free(v);
    }
    gtk_box_append(GTK_BOX(c->cost), cost);
    if (!sliced) gtk_box_append(GTK_BOX(c->cost), dim_label("An estimate. The slice gives the count.", "dim-label"));
    const char *kind = json_object_get_string_member_with_default(info, "kind", "");
    int top = (int)lround(json_object_get_double_member_with_default(info, "top_changes", -1));
    if (g_strcmp0(kind, "side") == 0 && n > 10 && top >= 0) {
        v = g_strdup_printf("On the top face, this label costs %d %s.", top, top == 1 ? "change" : "changes");
        gtk_box_append(GTK_BOX(c->cost), dim_label(v, "zg-explain"));
        g_free(v);
    }
}

/* ---- the place ---- */

void zg_label_card_place(GtkWidget *card, GtkWidget *host, const double box[4]) {
    LabelCard *c = card_of(card);
    if (!gtk_widget_get_visible(card)) return;
    /* The body scrolls in a short view. */
    double area[4], x, y;
    zg_free_area(host, area);
    int max = MAX(160, (int)(area[3] - area[1]) - 70);
    if (gtk_scrolled_window_get_max_content_height(GTK_SCROLLED_WINDOW(c->scroll)) != max)
        gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(c->scroll), max);
    if (zg_float_user_moved(card)) return;
    int w = gtk_widget_get_width(card), h = gtk_widget_get_height(card);
    if (w <= 0) w = 340;
    if (h <= 0) h = 300;
    if (box) zg_place_beside(box, area, w, h, &x, &y);
    else {
        x = area[2] - w;
        y = area[1] + 52;
    }
    double ox, oy;
    if (zg_float_get(card, &ox, &oy) && fabs(ox - x) < 0.5 && fabs(oy - y) < 0.5) return;
    zg_float_place(card, x, y);
}

/* ---- the card ---- */

static void card_free(gpointer data) {
    LabelCard *c = data;
    if (c->idle) g_source_remove(c->idle);
    zg_label_free(c->label);
    g_free(c->key);
    g_ptr_array_unref(c->inputs);
    g_free(c);
}

GtkWidget *zg_label_card_new(ZgModel *model, ZgLabelTool *tool) {
    LabelCard *c = g_new0(LabelCard, 1);
    c->model = model;
    c->tool = tool;
    c->inputs = g_ptr_array_new_with_free_func(input_free);
    c->card = zg_card_new();
    gtk_widget_add_css_class(c->card, "zg-label-card");
    gtk_widget_set_size_request(c->card, 340, -1);
    gtk_widget_set_halign(c->card, GTK_ALIGN_START);
    gtk_widget_set_valign(c->card, GTK_ALIGN_START);
    GtkWidget *head;
    c->title = zg_card_head(c->card, &head, NULL, G_CALLBACK(on_close), c);
    gtk_widget_set_tooltip_text(head, "Drag to move the card");
    zg_float_movable(c->card, head, NULL, NULL);
    c->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(c->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(c->scroll), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(c->scroll), 600);
    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(c->scroll), body);
    gtk_box_append(GTK_BOX(c->card), c->scroll);
    /* The notices: the filament of the part, and a face that curves. */
    c->notice = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    c->notice_text = dim_label("", "zg-note");
    c->notice_add = gtk_button_new_with_label("Add a filament");
    gtk_widget_set_tooltip_text(c->notice_add, "Add a second filament to the plate, and print the label with it");
    gtk_widget_add_css_class(c->notice_add, "zg-card-action");
    gtk_widget_set_halign(c->notice_add, GTK_ALIGN_START);
    g_signal_connect(c->notice_add, "clicked", G_CALLBACK(on_add_filament), c);
    gtk_box_append(GTK_BOX(c->notice), c->notice_text);
    gtk_box_append(GTK_BOX(c->notice), c->notice_add);
    gtk_widget_set_visible(c->notice, FALSE);
    gtk_box_append(GTK_BOX(body), c->notice);
    c->curve_note = dim_label(ZG_LABEL_CURVE_TEXT, "zg-note");
    gtk_widget_set_visible(c->curve_note, FALSE);
    gtk_box_append(GTK_BOX(body), c->curve_note);
    /* The shapes. */
    c->items = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(body), c->items);
    const char *adds[ZG_LABEL_KINDS + 2] = {"+ Add a shape…"};
    for (int k = 0; k < ZG_LABEL_KINDS; k++) adds[k + 1] = zg_label_kind_names[k];
    c->add = gtk_drop_down_new_from_strings(adds);
    gtk_widget_set_tooltip_text(c->add, "Add a shape to this label: it shares the place, the turn, and the filament. Ticks go around the center, under the text.");
    gtk_widget_set_halign(c->add, GTK_ALIGN_START);
    g_signal_connect(c->add, "notify::selected", G_CALLBACK(on_add), c);
    c->svg = gtk_button_new_with_label("Place an SVG…");
    gtk_widget_set_tooltip_text(c->svg, "Put the filled shapes of an SVG file on the label. You can also drop an SVG file on a part.");
    gtk_widget_add_css_class(c->svg, "zg-card-action");
    gtk_widget_set_halign(c->svg, GTK_ALIGN_START);
    g_signal_connect(c->svg, "clicked", G_CALLBACK(on_svg), c);
    GtkWidget *add_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(add_row), c->add);
    gtk_box_append(GTK_BOX(add_row), c->svg);
    gtk_box_append(GTK_BOX(body), add_row);
    /* The turn. */
    GtkWidget *turn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *turn_name = dim_label("Turn", NULL);
    gtk_widget_set_hexpand(turn_name, TRUE);
    c->turn = spin(0, -180, 180, 1);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(c->turn), 1);
    gtk_widget_set_tooltip_text(c->turn, "The turn of the label on the face (0: level). The wheel over the label turns it 1° (Shift: 15°).");
    g_object_set_data(G_OBJECT(c->turn), "zg-input", add_input(c, c->turn, -1, "turn"));
    g_signal_connect(c->turn, "changed", G_CALLBACK(on_number), c);
    GtkWidget *deg = gtk_label_new("°");
    gtk_widget_add_css_class(deg, "dim-label");
    gtk_box_append(GTK_BOX(turn_row), turn_name);
    gtk_box_append(GTK_BOX(turn_row), c->turn);
    gtk_box_append(GTK_BOX(turn_row), deg);
    gtk_box_append(GTK_BOX(body), turn_row);
    /* The mode: ink, raised, or cut in, and the relief. */
    GtkWidget *mode_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *mode_name = dim_label("Print", NULL);
    gtk_widget_set_hexpand(mode_name, TRUE);
    gtk_box_append(GTK_BOX(mode_row), mode_name);
    GtkWidget *modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(modes, "linked");
    static const char *const mode_tips[ZG_LABEL_MODES] = {"Flush with the surface, in the filament of the label", "Out of the surface by the relief",
                                                          "Cut into the surface by the relief"};
    for (int k = 0; k < ZG_LABEL_MODES; k++) {
        c->mode[k] = gtk_toggle_button_new_with_label(zg_label_mode_names[k]);
        if (k > 0) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(c->mode[k]), GTK_TOGGLE_BUTTON(c->mode[0]));
        gtk_widget_set_tooltip_text(c->mode[k], mode_tips[k]);
        g_object_set_data(G_OBJECT(c->mode[k]), "zg-mode", GINT_TO_POINTER(k));
        g_signal_connect(c->mode[k], "toggled", G_CALLBACK(on_mode), c);
        gtk_box_append(GTK_BOX(modes), c->mode[k]);
    }
    gtk_box_append(GTK_BOX(mode_row), modes);
    gtk_box_append(GTK_BOX(body), mode_row);
    c->relief_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *relief_name = dim_label("Relief", NULL);
    gtk_widget_set_hexpand(relief_name, TRUE);
    GtkWidget *relief = spin(ZG_LABEL_DEFAULT_RELIEF, 0.1, 10, 0.1);
    gtk_widget_set_tooltip_text(relief, "The height of a raised label, or the depth of a cut, mm");
    g_object_set_data(G_OBJECT(relief), "zg-input", add_input(c, relief, -1, "relief"));
    g_signal_connect(relief, "changed", G_CALLBACK(on_number), c);
    GtkWidget *rmm = gtk_label_new("mm");
    gtk_widget_add_css_class(rmm, "dim-label");
    gtk_box_append(GTK_BOX(c->relief_row), relief_name);
    gtk_box_append(GTK_BOX(c->relief_row), relief);
    gtk_box_append(GTK_BOX(c->relief_row), rmm);
    gtk_widget_set_visible(c->relief_row, FALSE);
    gtk_box_append(GTK_BOX(body), c->relief_row);
    /* The filament. */
    gtk_box_append(GTK_BOX(body), heading("Filament"));
    c->chips = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(c->chips), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(c->chips), 12);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(c->chips), 4);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(c->chips), 4);
    gtk_box_append(GTK_BOX(body), c->chips);
    /* The depth: 1 line, 2 lines, or mm. */
    GtkWidget *depth_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *depth_name = dim_label("Depth", NULL);
    gtk_widget_set_hexpand(depth_name, TRUE);
    gtk_box_append(GTK_BOX(depth_row), depth_name);
    GtkWidget *lines = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(lines, "linked");
    c->depth1 = gtk_toggle_button_new_with_label("1 line");
    c->depth2 = gtk_toggle_button_new_with_label("2 lines");
    gtk_widget_set_tooltip_text(c->depth1, "The color is one line deep (the outer wall)");
    gtk_widget_set_tooltip_text(c->depth2, "The color is two lines deep: more color for a light filament over a dark part");
    g_signal_connect(c->depth1, "toggled", G_CALLBACK(on_depth_lines), c);
    g_signal_connect(c->depth2, "toggled", G_CALLBACK(on_depth_lines), c);
    gtk_box_append(GTK_BOX(lines), c->depth1);
    gtk_box_append(GTK_BOX(lines), c->depth2);
    gtk_box_append(GTK_BOX(depth_row), lines);
    c->depth_mm = spin(0, 0, 10, 0.01);
    gtk_widget_set_tooltip_text(c->depth_mm, "The depth of the color from the surface, mm (0: one line)");
    g_object_set_data(G_OBJECT(c->depth_mm), "zg-input", add_input(c, c->depth_mm, -1, "depth"));
    g_signal_connect(c->depth_mm, "changed", G_CALLBACK(on_number), c);
    gtk_box_append(GTK_BOX(depth_row), c->depth_mm);
    GtkWidget *mm = gtk_label_new("mm");
    gtk_widget_add_css_class(mm, "dim-label");
    gtk_box_append(GTK_BOX(depth_row), mm);
    gtk_box_append(GTK_BOX(body), depth_row);
    /* The stroke check and the cost. */
    gtk_box_append(GTK_BOX(body), heading("Print"));
    c->check = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    c->cost = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(body), c->check);
    gtk_box_append(GTK_BOX(body), c->cost);
    GtkWidget *del = gtk_button_new_with_label("Delete the label");
    gtk_widget_set_tooltip_text(del, "Remove the label from the part (Delete)");
    gtk_widget_add_css_class(del, "destructive-action");
    gtk_widget_add_css_class(del, "zg-card-action");
    gtk_widget_set_halign(del, GTK_ALIGN_START);
    gtk_widget_set_margin_top(del, 4);
    g_signal_connect(del, "clicked", G_CALLBACK(on_delete), c);
    gtk_box_append(GTK_BOX(body), del);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(c->card, keys);
    gtk_widget_set_visible(c->card, FALSE);
    g_object_set_data_full(G_OBJECT(c->card), "zg-label-card", c, card_free);
    return c->card;
}
