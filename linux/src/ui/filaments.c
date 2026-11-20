/* filaments.c: see filaments.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "filaments.h"

#include "../prefs/printers.h"

#include <string.h>

/* The most filaments of a plate (src/app/filament_slots.zig), and the
 * most dots on the button. */
enum { MAX_FILAMENTS = 16, MAX_DOTS = 8, CHIP_PX = 26, DOT_PX = 10 };

static const char *const materials[] = {"PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA", NULL};

void zg_filament_rgb(const char *color, double rgb[3]) {
    unsigned r, g, b;
    if (color && strlen(color) == 7 && color[0] == '#' && sscanf(color + 1, "%02x%02x%02x", &r, &g, &b) == 3) {
        rgb[0] = r / 255.0;
        rgb[1] = g / 255.0;
        rgb[2] = b / 255.0;
        return;
    }
    /* #d0d0cc, as on the web. */
    rgb[0] = 0xd0 / 255.0;
    rgb[1] = 0xd0 / 255.0;
    rgb[2] = 0xcc / 255.0;
}

/* ---- the chips ---- */

typedef struct {
    double rgb[3];
    gboolean selected;
    char *text;
} Chip;

static void chip_free(gpointer data) {
    Chip *c = data;
    g_free(c->text);
    g_free(c);
}

static void draw_chip(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    Chip *c = data;
    GdkRGBA fg;
    gtk_widget_get_color(GTK_WIDGET(area), &fg);
    double cx = w / 2.0, cy = h / 2.0, r = MIN(w, h) / 2.0 - 3;
    cairo_arc(cr, cx, cy, r, 0, 2 * G_PI);
    cairo_set_source_rgb(cr, c->rgb[0], c->rgb[1], c->rgb[2]);
    cairo_fill_preserve(cr);
    /* A thin edge, so that a white filament shows on a light theme. */
    cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.35);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);
    if (c->selected) {
        cairo_arc(cr, cx, cy, r + 2, 0, 2 * G_PI);
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, fg.alpha);
        cairo_set_line_width(cr, 2);
        cairo_stroke(cr);
    }
    if (c->text && c->text[0]) {
        /* Black or white text on the color. */
        double lum = 0.2126 * c->rgb[0] + 0.7152 * c->rgb[1] + 0.0722 * c->rgb[2];
        double ink = lum > 0.55 ? 0.07 : 1.0;
        PangoLayout *layout = gtk_widget_create_pango_layout(GTK_WIDGET(area), c->text);
        int tw, th;
        pango_layout_get_pixel_size(layout, &tw, &th);
        cairo_move_to(cr, cx - tw / 2.0, cy - th / 2.0);
        cairo_set_source_rgb(cr, ink, ink, ink);
        pango_cairo_show_layout(cr, layout);
        g_object_unref(layout);
    }
}

GtkWidget *zg_filament_chip_new(const char *color, const char *text, gboolean selected) {
    GtkWidget *b;
    if (color) {
        Chip *c = g_new0(Chip, 1);
        zg_filament_rgb(color, c->rgb);
        c->selected = selected;
        c->text = g_strdup(text);
        GtkWidget *area = gtk_drawing_area_new();
        gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), CHIP_PX);
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), CHIP_PX);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_chip, c, chip_free);
        b = gtk_button_new();
        gtk_button_set_child(GTK_BUTTON(b), area);
        gtk_widget_add_css_class(b, "zg-fil-chip");
    } else {
        b = gtk_button_new_with_label(text);
        gtk_widget_add_css_class(b, "zg-fil-text");
        if (selected) gtk_widget_add_css_class(b, "zg-on");
    }
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_set_valign(b, GTK_ALIGN_CENTER);
    gtk_widget_set_focus_on_click(b, FALSE);
    return b;
}

/* ---- following the changes ---- */

typedef struct {
    ZgModel *model;
    GtkWidget *owner;
    void (*redraw)(GtkWidget *owner);
    gboolean slices;
    guint idle;
    gulong handlers[6];
} Follow;

static gboolean on_follow_idle(gpointer data) {
    Follow *f = data;
    f->idle = 0;
    f->redraw(f->owner);
    return G_SOURCE_REMOVE;
}

static void follow_soon(Follow *f) {
    if (!f->idle) f->idle = g_idle_add(on_follow_idle, f);
}

static void on_follow_any(ZgModel *model, gpointer data) {
    follow_soon(data);
}

static void on_follow_setting(ZgModel *model, const char *key, gpointer data) {
    /* The filament settings are filament 0. The machine settings have
     * the nozzles and the kind of filament change. */
    if (g_str_has_prefix(key, "filament.") || g_str_has_prefix(key, "machine.")) follow_soon(data);
}

static void on_follow_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    Follow *f = data;
    if (f->slices && event == ZS_EVENT_SLICED) follow_soon(f);
}

static void follow_free(gpointer data) {
    Follow *f = data;
    if (f->idle) g_source_remove(f->idle);
    for (size_t i = 0; i < G_N_ELEMENTS(f->handlers); i++)
        if (f->handlers[i]) g_signal_handler_disconnect(f->model, f->handlers[i]);
    g_object_unref(f->model);
    g_free(f);
}

void zg_filaments_follow(ZgModel *model, GtkWidget *owner, gboolean slices, void (*redraw)(GtkWidget *owner)) {
    Follow *f = g_new0(Follow, 1);
    f->model = g_object_ref(model);
    f->owner = owner;
    f->redraw = redraw;
    f->slices = slices;
    f->handlers[0] = g_signal_connect(model, "filaments-changed", G_CALLBACK(on_follow_any), f);
    f->handlers[1] = g_signal_connect(model, "plates-changed", G_CALLBACK(on_follow_any), f);
    f->handlers[2] = g_signal_connect(model, "plate-changed", G_CALLBACK(on_follow_any), f);
    f->handlers[3] = g_signal_connect(model, "printer-changed", G_CALLBACK(on_follow_any), f);
    f->handlers[4] = g_signal_connect(model, "setting-changed", G_CALLBACK(on_follow_setting), f);
    f->handlers[5] = g_signal_connect(model, "core-event", G_CALLBACK(on_follow_event), f);
    /* A new key for each call: an owner can follow more than once. */
    char key[32];
    g_snprintf(key, sizeof key, "zg-follow-%p", (void *)f);
    g_object_set_data_full(G_OBJECT(owner), key, f, follow_free);
}

/* ---- the button and its list ---- */

typedef struct Button Button;

typedef struct {
    Button *b;
    size_t index;
    GtkWidget *color, *mat, *nozzle, *grams;
    GtkStringList *mats;
} Row;

struct Button {
    ZgModel *model;
    GtkWidget *button, *dots, *label;
    GtkWidget *popover, *head, *list, *add, *note;
    GPtrArray *rows; /* Row */
    gboolean two;    /* the rows have a nozzle choice */
    gboolean filling;
    /* The colors of the dots. */
    double dot_rgb[MAX_DOTS][3];
    int n_dots;
};

static gboolean two_nozzles(ZgModel *model) {
    char *n = zg_model_get(model, "machine.nozzles");
    gboolean two = g_ascii_strtod(n, NULL) >= 2;
    g_free(n);
    return two;
}

static void draw_dots(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    Button *b = data;
    GdkRGBA fg;
    gtk_widget_get_color(GTK_WIDGET(area), &fg);
    double r = DOT_PX / 2.0 - 0.5;
    for (int i = 0; i < b->n_dots; i++) {
        /* The dots overlap a little, as on the web. */
        double cx = DOT_PX / 2.0 + i * (DOT_PX - 3), cy = h / 2.0;
        cairo_arc(cr, cx, cy, r, 0, 2 * G_PI);
        cairo_set_source_rgb(cr, b->dot_rgb[i][0], b->dot_rgb[i][1], b->dot_rgb[i][2]);
        cairo_fill_preserve(cr);
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.4);
        cairo_set_line_width(cr, 1);
        cairo_stroke(cr);
    }
}

/* The button: a dot for each filament, and the name of the filament or
 * the count. */
static void update_button(Button *b) {
    size_t n = zs_app_filament_count(zg_model_core(b->model));
    b->n_dots = (int)MIN(n, (size_t)MAX_DOTS);
    for (int i = 0; i < b->n_dots; i++) {
        char *c = zg_model_filament_get(b->model, (size_t)i, "filament.color");
        zg_filament_rgb(c, b->dot_rgb[i]);
        g_free(c);
    }
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(b->dots), b->n_dots > 0 ? DOT_PX + (b->n_dots - 1) * (DOT_PX - 3) : 0);
    gtk_widget_queue_draw(b->dots);
    if (n > 1) {
        char *text = g_strdup_printf("%zu filaments", n);
        gtk_label_set_text(GTK_LABEL(b->label), text);
        g_free(text);
        char *tip = g_strdup_printf("The %zu filaments of the plate: click to change them", n);
        gtk_widget_set_tooltip_text(b->button, tip);
        g_free(tip);
    } else {
        char *name = zg_model_get(b->model, "filament.name");
        gtk_label_set_text(GTK_LABEL(b->label), name[0] ? name : "Filament");
        g_free(name);
        gtk_widget_set_tooltip_text(b->button, "The filament: click to change it, or to add filaments");
    }
}

static void row_free(gpointer data) {
    g_free(data);
}

static void set_value(Button *b, size_t i, const char *name, const char *value) {
    GError *error = NULL;
    if (!zg_model_filament_set(b->model, i, name, value, &error)) {
        g_warning("filament %zu: %s = %s: %s", i + 1, name, value, error->message);
        g_error_free(error);
    }
}

static void on_color(GObject *button, GParamSpec *pspec, gpointer data) {
    Row *r = data;
    if (r->b->filling) return;
    const GdkRGBA *c = gtk_color_dialog_button_get_rgba(GTK_COLOR_DIALOG_BUTTON(button));
    char hex[8];
    g_snprintf(hex, sizeof hex, "#%02x%02x%02x", (int)(CLAMP(c->red, 0, 1) * 255 + 0.5), (int)(CLAMP(c->green, 0, 1) * 255 + 0.5),
               (int)(CLAMP(c->blue, 0, 1) * 255 + 0.5));
    set_value(r->b, r->index, "filament.color", hex);
}

static void on_material(GObject *dd, GParamSpec *pspec, gpointer data) {
    Row *r = data;
    if (r->b->filling) return;
    GtkStringObject *item = gtk_drop_down_get_selected_item(GTK_DROP_DOWN(dd));
    if (item) set_value(r->b, r->index, "filament.material", gtk_string_object_get_string(item));
}

static void on_nozzle(GObject *dd, GParamSpec *pspec, gpointer data) {
    Row *r = data;
    if (r->b->filling) return;
    set_value(r->b, r->index, "filament.nozzle", gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)) == 1 ? "1" : "0");
}

static void on_remove(GtkButton *button, gpointer data) {
    Row *r = data;
    zg_model_filament_remove(r->b->model, r->index);
}

static void on_add(GtkButton *button, gpointer data) {
    Button *b = data;
    zg_model_filament_add(b->model);
}

/* Shows the values of filament r->index in its row. */
static void fill_row(Row *r, const double *grams, size_t n_grams) {
    Button *b = r->b;
    char *color = zg_model_filament_get(b->model, r->index, "filament.color");
    double rgb[3];
    zg_filament_rgb(color, rgb);
    GdkRGBA rgba = {(float)rgb[0], (float)rgb[1], (float)rgb[2], 1};
    const GdkRGBA *now = gtk_color_dialog_button_get_rgba(GTK_COLOR_DIALOG_BUTTON(r->color));
    if (!now || !gdk_rgba_equal(now, &rgba)) gtk_color_dialog_button_set_rgba(GTK_COLOR_DIALOG_BUTTON(r->color), &rgba);
    g_free(color);
    /* A material that is not in the list goes first. */
    char *mat = zg_model_filament_get(b->model, r->index, "filament.material");
    if (!mat[0]) {
        g_free(mat);
        mat = g_strdup("PLA");
    }
    guint n = g_list_model_get_n_items(G_LIST_MODEL(r->mats)), at = G_MAXUINT;
    for (guint k = 0; k < n; k++)
        if (strcmp(gtk_string_list_get_string(r->mats, k), mat) == 0) at = k;
    if (at == G_MAXUINT) {
        /* The list: the known materials, after this one. */
        const char *one[] = {mat, NULL};
        gtk_string_list_splice(r->mats, 0, n - (guint)(G_N_ELEMENTS(materials) - 1), one);
        at = 0;
    }
    if (gtk_drop_down_get_selected(GTK_DROP_DOWN(r->mat)) != at) gtk_drop_down_set_selected(GTK_DROP_DOWN(r->mat), at);
    char *tip = g_strdup_printf("The material of filament %zu", r->index + 1);
    gtk_widget_set_tooltip_text(r->mat, tip);
    g_free(tip);
    g_free(mat);
    if (r->nozzle) {
        char *nz = zg_model_filament_get(b->model, r->index, "filament.nozzle");
        guint sel = g_ascii_strtod(nz, NULL) >= 1 ? 1 : 0;
        if (gtk_drop_down_get_selected(GTK_DROP_DOWN(r->nozzle)) != sel) gtk_drop_down_set_selected(GTK_DROP_DOWN(r->nozzle), sel);
        g_free(nz);
    }
    if (r->index < n_grams && grams[r->index] > 0) {
        char *g = g_strdup_printf("%.1f g", grams[r->index]);
        gtk_label_set_text(GTK_LABEL(r->grams), g);
        g_free(g);
    } else {
        gtk_label_set_text(GTK_LABEL(r->grams), "");
    }
}

static void add_row(Button *b, size_t i) {
    Row *r = g_new0(Row, 1);
    r->b = b;
    r->index = i;
    int col = 0;
    GtkWidget *grid = b->list;
    int y = (int)i;

    GtkColorDialog *dialog = gtk_color_dialog_new();
    gtk_color_dialog_set_with_alpha(dialog, FALSE);
    char *title = g_strdup_printf("The color of filament %zu", i + 1);
    gtk_color_dialog_set_title(dialog, title);
    r->color = gtk_color_dialog_button_new(dialog);
    gtk_widget_set_tooltip_text(r->color, title);
    g_free(title);
    gtk_widget_set_valign(r->color, GTK_ALIGN_CENTER);
    gtk_grid_attach(GTK_GRID(grid), r->color, col++, y, 1, 1);

    char *num = g_strdup_printf("%zu", i + 1);
    GtkWidget *label = gtk_label_new(num);
    g_free(num);
    gtk_widget_add_css_class(label, "numeric");
    gtk_grid_attach(GTK_GRID(grid), label, col++, y, 1, 1);

    r->mats = gtk_string_list_new(materials);
    r->mat = gtk_drop_down_new(G_LIST_MODEL(r->mats), NULL);
    gtk_widget_set_valign(r->mat, GTK_ALIGN_CENTER);
    gtk_grid_attach(GTK_GRID(grid), r->mat, col++, y, 1, 1);

    if (b->two) {
        const char *const nozzles[] = {"Main", "2nd", NULL};
        r->nozzle = gtk_drop_down_new_from_strings(nozzles);
        gtk_widget_set_valign(r->nozzle, GTK_ALIGN_CENTER);
        char *tip = g_strdup_printf("The nozzle of filament %zu: the main nozzle (fed by the AMS on the X2D), or the second nozzle (fed by the external spool)", i + 1);
        gtk_widget_set_tooltip_text(r->nozzle, tip);
        g_free(tip);
        gtk_grid_attach(GTK_GRID(grid), r->nozzle, col++, y, 1, 1);
    }

    r->grams = gtk_label_new("");
    gtk_widget_add_css_class(r->grams, "dim-label");
    gtk_widget_add_css_class(r->grams, "numeric");
    gtk_label_set_xalign(GTK_LABEL(r->grams), 1);
    gtk_label_set_width_chars(GTK_LABEL(r->grams), 7);
    gtk_grid_attach(GTK_GRID(grid), r->grams, col++, y, 1, 1);

    if (i > 0) {
        GtkWidget *rm = gtk_button_new_with_label("×");
        gtk_widget_add_css_class(rm, "flat");
        gtk_widget_set_valign(rm, GTK_ALIGN_CENTER);
        char *tip = g_strdup_printf("Remove filament %zu. Its parts and layers print with filament 1.", i + 1);
        gtk_widget_set_tooltip_text(rm, tip);
        g_free(tip);
        g_signal_connect(rm, "clicked", G_CALLBACK(on_remove), r);
        gtk_grid_attach(GTK_GRID(grid), rm, col, y, 1, 1);
    }

    g_signal_connect(r->color, "notify::rgba", G_CALLBACK(on_color), r);
    g_signal_connect(r->mat, "notify::selected", G_CALLBACK(on_material), r);
    if (r->nozzle) g_signal_connect(r->nozzle, "notify::selected", G_CALLBACK(on_nozzle), r);
    g_ptr_array_add(b->rows, r);
}

/* The list in the popover. It makes the rows again only for another count
 * or another nozzle mode, so a color button with its dialog open stays. */
static void update_list(Button *b) {
    zs_app *core = zg_model_core(b->model);
    size_t n = zs_app_filament_count(core);
    gboolean two = two_nozzles(b->model);
    b->filling = TRUE;
    if (n != b->rows->len || two != b->two) {
        GtkWidget *c;
        while ((c = gtk_widget_get_first_child(b->list))) gtk_grid_remove(GTK_GRID(b->list), c);
        g_ptr_array_set_size(b->rows, 0);
        b->two = two;
        for (size_t i = 0; i < n; i++) add_row(b, i);
    }
    double grams[MAX_FILAMENTS] = {0};
    uint32_t changes = 0;
    double flush = 0;
    size_t n_grams = zs_app_filament_stats(core, grams, MAX_FILAMENTS, &changes, &flush) == ZS_OK ? MAX_FILAMENTS : 0;
    for (guint i = 0; i < b->rows->len; i++) fill_row(g_ptr_array_index(b->rows, i), grams, n_grams);
    b->filling = FALSE;

    GString *head = g_string_new(n > 1 ? NULL : "Filament");
    if (n > 1) g_string_append_printf(head, "%zu filaments", n);
    if (n_grams && changes > 0) {
        g_string_append_printf(head, " · %u %s", changes, changes == 1 ? "change" : "changes");
        if (flush > 0.05) g_string_append_printf(head, " · flush %.1f g", flush);
    }
    gtk_label_set_text(GTK_LABEL(b->head), head->str);
    g_string_free(head, TRUE);
    gtk_widget_set_visible(b->add, n < MAX_FILAMENTS);

    char *change = zg_model_get(b->model, "machine.filament_change");
    if (strcmp(change, "tool") == 0) {
        char *note = g_strdup_printf("%s changes the filament by itself. Add the filaments it has, then give a part or layers a filament.",
                                     zg_printers_current()->name);
        gtk_label_set_text(GTK_LABEL(b->note), note);
        g_free(note);
    } else {
        gtk_label_set_text(GTK_LABEL(b->note), "Add a filament to print in more colors: the print pauses at each change.");
    }
    g_free(change);
}

static void redraw(GtkWidget *owner) {
    Button *b = g_object_get_data(G_OBJECT(owner), "zg-filaments");
    update_button(b);
    if (gtk_widget_get_visible(b->popover)) update_list(b);
}

static void on_popover_show(GtkWidget *popover, gpointer data) {
    update_list(data);
}

static void button_free(gpointer data) {
    Button *b = data;
    g_ptr_array_unref(b->rows);
    g_free(b);
}

/* For tests and screenshots: ZSLICE_FILAMENTS=n makes n filaments, and
 * opens the list. */
static gboolean test_hook(gpointer data) {
    Button *b = data;
    size_t want = (size_t)g_ascii_strtoull(g_getenv("ZSLICE_FILAMENTS"), NULL, 10);
    while (zs_app_filament_count(zg_model_core(b->model)) < want && zg_model_filament_add(b->model) >= 0) {}
    gtk_menu_button_popup(GTK_MENU_BUTTON(b->button));
    return G_SOURCE_REMOVE;
}

GtkWidget *zg_filament_button_new(ZgModel *model) {
    Button *b = g_new0(Button, 1);
    b->model = model;
    b->rows = g_ptr_array_new_with_free_func(row_free);
    b->button = gtk_menu_button_new();
    gtk_widget_set_focus_on_click(b->button, FALSE);
    GtkWidget *face = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    b->dots = gtk_drawing_area_new();
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(b->dots), DOT_PX + 2);
    gtk_widget_set_valign(b->dots, GTK_ALIGN_CENTER);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(b->dots), draw_dots, b, NULL);
    b->label = gtk_label_new("Filament");
    gtk_label_set_wrap(GTK_LABEL(b->label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(b->label), PANGO_WRAP_WORD);
    gtk_box_append(GTK_BOX(face), b->dots);
    gtk_box_append(GTK_BOX(face), b->label);
    gtk_menu_button_set_child(GTK_MENU_BUTTON(b->button), face);

    b->popover = gtk_popover_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 6);
    gtk_widget_set_margin_end(box, 6);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);
    b->head = gtk_label_new("Filament");
    gtk_label_set_xalign(GTK_LABEL(b->head), 0);
    gtk_widget_add_css_class(b->head, "heading");
    gtk_box_append(GTK_BOX(box), b->head);
    b->list = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(b->list), 6);
    gtk_grid_set_row_spacing(GTK_GRID(b->list), 4);
    gtk_box_append(GTK_BOX(box), b->list);
    b->add = gtk_button_new_with_label("+ Add a filament");
    gtk_widget_add_css_class(b->add, "flat");
    gtk_widget_set_halign(b->add, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(b->add, "Add a filament to the plate. A part or a range of layers can then print with it.");
    g_signal_connect(b->add, "clicked", G_CALLBACK(on_add), b);
    gtk_box_append(GTK_BOX(box), b->add);
    b->note = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(b->note), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(b->note), 40);
    gtk_label_set_xalign(GTK_LABEL(b->note), 0);
    gtk_widget_add_css_class(b->note, "zg-fil-note");
    gtk_box_append(GTK_BOX(box), b->note);
    gtk_popover_set_child(GTK_POPOVER(b->popover), box);
    g_signal_connect(b->popover, "show", G_CALLBACK(on_popover_show), b);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(b->button), b->popover);

    g_object_set_data_full(G_OBJECT(b->button), "zg-filaments", b, button_free);
    zg_filaments_follow(model, b->button, TRUE, redraw);
    update_button(b);
    if (g_getenv("ZSLICE_FILAMENTS")) g_timeout_add(2500, test_hook, b);
    return b->button;
}
