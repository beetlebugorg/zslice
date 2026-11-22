/* filaments.c: see filaments.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "filaments.h"

#include "../net/deck-filaments.h"
#include "../net/printer-link.h"
#include "../prefs/printers.h"

#include <math.h>
#include <stdlib.h>
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

guint32 zg_filament_rgb24(ZgModel *model, int filament) {
    char *c = zg_model_filament_get(model, (size_t)MAX(filament - 1, 0), "filament.color");
    if (!c || !c[0]) {
        g_free(c);
        c = zg_model_filament_get(model, 0, "filament.color");
    }
    double rgb[3];
    zg_filament_rgb(c, rgb);
    g_free(c);
    return ((guint32)lround(rgb[0] * 255) << 16) | ((guint32)lround(rgb[1] * 255) << 8) | (guint32)lround(rgb[2] * 255);
}

int zg_part_filament(ZgModel *model, gint64 index) {
    char *own = index >= 0 ? zg_model_part_setting(model, (size_t)index, "project.filament") : NULL;
    char *v = own ? own : zg_model_get(model, "project.filament");
    int f = atoi(v ? v : "1");
    g_free(v);
    return f > 0 ? f : 1;
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
    /* "Use the filaments of <printer>" (a printdeck printer), and the
     * result of the last use. */
    GtkWidget *use, *use_result;
    GCancellable *cancel;
    gboolean reading;
    GPtrArray *rows; /* Row */
    int nozzles;     /* the nozzles of the printer: a nozzle choice for 2 or more */
    gboolean filling;
    /* The colors of the dots. */
    double dot_rgb[MAX_DOTS][3];
    int n_dots;
};

/* The number of nozzles of the printer (machine.nozzles). */
static int nozzle_count(ZgModel *model) {
    char *n = zg_model_get(model, "machine.nozzles");
    int count = (int)g_ascii_strtod(n, NULL);
    g_free(n);
    return count < 1 ? 1 : count > 16 ? 16 : count;
}

static gboolean two_nozzles(ZgModel *model) {
    return nozzle_count(model) >= 2;
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
    /* The filaments that come from the spools of the printer. */
    gboolean from = n > 0;
    for (size_t i = 0; i < n && from; i++) {
        char *p = zg_model_filament_get(b->model, i, "source.printer");
        from = strcmp(p, "1") == 0;
        g_free(p);
    }
    const char *more = from ? " · From the printer" : "";
    if (n > 1) {
        char *text = g_strdup_printf("%zu filaments%s", n, more);
        gtk_label_set_text(GTK_LABEL(b->label), text);
        g_free(text);
        char *tip = g_strdup_printf("The %zu filaments of the plate: click to change them%s", n,
                                    from ? ". They are the spools in the printer." : "");
        gtk_widget_set_tooltip_text(b->button, tip);
        g_free(tip);
    } else {
        char *name = zg_model_get(b->model, "filament.name");
        char *text = g_strdup_printf("%s%s", name[0] ? name : "Filament", more);
        gtk_label_set_text(GTK_LABEL(b->label), text);
        g_free(text);
        g_free(name);
        gtk_widget_set_tooltip_text(b->button, from ? "The filament: the spool in the printer. Click to change it, or to add filaments"
                                                    : "The filament: click to change it, or to add filaments");
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
    guint sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (sel == GTK_INVALID_LIST_POSITION) return;
    char value[8];
    g_snprintf(value, sizeof value, "%u", sel);
    set_value(r->b, r->index, "filament.nozzle", value);
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
        /* A nozzle that the printer does not have: no choice (the Check
         * tells it). */
        char *nz = zg_model_filament_get(b->model, r->index, "filament.nozzle");
        guint k = (guint)g_ascii_strtod(nz, NULL);
        guint sel = k < (guint)b->nozzles ? k : GTK_INVALID_LIST_POSITION;
        if (gtk_drop_down_get_selected(GTK_DROP_DOWN(r->nozzle)) != sel) gtk_drop_down_set_selected(GTK_DROP_DOWN(r->nozzle), sel);
        g_free(nz);
    }
    /* The spool of the printer that the filament comes from ("A1"). */
    char *from = zg_model_filament_get(b->model, r->index, "source.printer");
    char *slot = zg_model_filament_get(b->model, r->index, "source.slot");
    char *hand = zg_model_filament_get(b->model, r->index, "source.hand");
    gboolean printer = strcmp(from, "1") == 0;
    GString *g = g_string_new(printer ? (slot[0] ? slot : "Printer") : "");
    if (r->index < n_grams && grams[r->index] > 0) g_string_append_printf(g, "%s%.1f g", g->len ? " · " : "", grams[r->index]);
    gtk_label_set_text(GTK_LABEL(r->grams), g->str);
    g_string_free(g, TRUE);
    if (printer) {
        char *tip = slot[0] ? g_strdup_printf("From the printer: the spool in %s", slot) : g_strdup("From the printer: its spool");
        gtk_widget_set_tooltip_text(r->grams, tip);
        g_free(tip);
    } else {
        gtk_widget_set_tooltip_text(r->grams, strcmp(hand, "1") == 0 ? "You set this filament. It stays when the printer has other spools." : NULL);
    }
    g_free(from);
    g_free(slot);
    g_free(hand);
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

    if (b->nozzles >= 2) {
        /* Two nozzles (the X2D): the main and the second. More: the tools
         * T0 and on. */
        GtkStringList *names = gtk_string_list_new(NULL);
        for (int k = 0; k < b->nozzles; k++) {
            char *label = b->nozzles == 2 ? g_strdup(k == 0 ? "Main" : "2nd") : g_strdup_printf("T%d", k);
            gtk_string_list_append(names, label);
            g_free(label);
        }
        r->nozzle = gtk_drop_down_new(G_LIST_MODEL(names), NULL);
        gtk_widget_set_valign(r->nozzle, GTK_ALIGN_CENTER);
        char *tip = b->nozzles == 2
                        ? g_strdup_printf("The nozzle of filament %zu: the main nozzle (fed by the AMS on the X2D), or the second nozzle (fed by the external spool)", i + 1)
                        : g_strdup_printf("The nozzle of filament %zu: the tool that prints it (T0 to T%d)", i + 1, b->nozzles - 1);
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
    int nozzles = nozzle_count(b->model);
    b->filling = TRUE;
    if (n != b->rows->len || nozzles != b->nozzles) {
        GtkWidget *c;
        while ((c = gtk_widget_get_first_child(b->list))) gtk_grid_remove(GTK_GRID(b->list), c);
        g_ptr_array_set_size(b->rows, 0);
        b->nozzles = nozzles;
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
    GString *tip = g_string_new(NULL);
    if (n_grams && changes > 0) {
        /* The changes and the waste: the flushes out of the print and all
         * lines of the prime towers (zs_app_waste). */
        double chute = 0, tower = 0, total = 0, change_s = 0;
        zs_app_waste(core, &chute, &tower, &total, &change_s);
        g_string_append_printf(head, " · %u %s", changes, changes == 1 ? "change" : "changes");
        if (change_s >= 60) g_string_append_printf(head, ", about %.0f min", change_s / 60);
        else if (change_s > 0) g_string_append_printf(head, ", about %.0f s", change_s);
        double waste = chute + tower;
        if (waste >= 0.05) {
            g_string_append_printf(head, " · waste %.1f g", waste);
            if (total > 0) g_string_append_printf(head, " (%.0f %%)", 100 * waste / total);
        }
        if (chute >= 0.05) g_string_append_printf(tip, "Flush out of the print: %.1f g\n", chute);
        if (tower >= 0.05) g_string_append_printf(tip, "Prime tower: %.1f g\n", tower);
        if (change_s > 0) g_string_append_printf(tip, "Filament changes: %.0f s", change_s);
    }
    gtk_label_set_text(GTK_LABEL(b->head), head->str);
    gtk_widget_set_tooltip_text(b->head, tip->len ? tip->str : NULL);
    g_string_free(tip, TRUE);
    g_string_free(head, TRUE);
    gtk_widget_set_visible(b->add, n < MAX_FILAMENTS);

    ZgPrinter *pr = zg_printers_current();
    gtk_widget_set_visible(b->use, pr->kind == ZG_LINK_PRINTDECK);
    gtk_widget_set_visible(b->use_result, pr->kind == ZG_LINK_PRINTDECK && gtk_label_get_text(GTK_LABEL(b->use_result))[0]);
    if (!b->reading) {
        char *use = g_strdup_printf("Use the filaments of %s", pr->name);
        gtk_button_set_label(GTK_BUTTON(b->use), use);
        g_free(use);
    }

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

/* ---- the filaments of a printdeck printer ---- */

/* Makes the filaments of the plate the spools of the printer
 * (zs_app_filaments_from_printer): the same count, then the material (its
 * built-in profile), the color, and the nozzle of each, in the order of
 * the printer. The filaments that the user set by hand follow too. Then
 * the nozzle of the printer. Returns the words for the user. */
static char *apply_loaded(Button *b, const ZgDeckFilaments *d, const char *body, gsize len, const char *name) {
    char *message = NULL;
    zg_model_filaments_from_printer(b->model, name, body, len, 1, &message);
    if (d->nozzle_type) {
        zg_model_set(b->model, "machine.nozzle_type", d->nozzle_type, NULL);
        zg_model_set(b->model, "machine.nozzle_flow", d->nozzle_flow, NULL);
        char *more = g_strdup_printf("%s Nozzles: %s, %s.", message ? message : "", d->nozzle_type, d->nozzle_flow);
        for (char *c = more; *c; c++)
            if (*c == '_') *c = ' ';
        g_free(message);
        message = more;
    }
    return message;
}

static void on_loaded(const char *body, gsize len, const char *error, gpointer data) {
    Button *b = data;
    b->reading = FALSE;
    gtk_widget_set_sensitive(b->use, TRUE);
    const char *name = zg_printers_current()->name;
    char *message = NULL;
    if (error) {
        message = g_strdup(error);
    } else {
        gboolean two = two_nozzles(b->model);
        char *why = NULL;
        ZgDeckFilaments *d = zg_deck_filaments_parse(body, (gssize)len, two, name, &why);
        if (d) {
            message = apply_loaded(b, d, body, len, name);
            zg_deck_filaments_free(d);
        } else {
            message = why;
        }
    }
    gtk_label_set_text(GTK_LABEL(b->use_result), message);
    g_free(message);
    update_list(b);
}

static void on_use(GtkButton *button, gpointer data) {
    Button *b = data;
    if (b->reading) return;
    b->reading = TRUE;
    gtk_widget_set_sensitive(b->use, FALSE);
    gtk_button_set_label(GTK_BUTTON(b->use), "Reading the printer\u2026");
    gtk_label_set_text(GTK_LABEL(b->use_result), "");
    zg_link_loaded_filaments(zg_printers_current(), b->cancel, on_loaded, b);
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
    g_cancellable_cancel(b->cancel);
    g_object_unref(b->cancel);
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
    /* ZSLICE_FILAMENTS_USE=1: then "Use the filaments of <printer>". */
    if (g_getenv("ZSLICE_FILAMENTS_USE") && gtk_widget_get_visible(b->use)) on_use(GTK_BUTTON(b->use), b);
    return G_SOURCE_REMOVE;
}

GtkWidget *zg_filament_button_new(ZgModel *model) {
    Button *b = g_new0(Button, 1);
    b->model = model;
    b->rows = g_ptr_array_new_with_free_func(row_free);
    b->cancel = g_cancellable_new();
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
    b->use = gtk_button_new_with_label("");
    gtk_widget_set_halign(b->use, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(b->use, "Read the spools that the printer has loaded (the AMS trays and the external spool), and make the filaments of the plate the same: count, material, and color");
    g_signal_connect(b->use, "clicked", G_CALLBACK(on_use), b);
    gtk_box_append(GTK_BOX(box), b->use);
    b->use_result = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(b->use_result), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(b->use_result), 40);
    gtk_label_set_xalign(GTK_LABEL(b->use_result), 0);
    gtk_box_append(GTK_BOX(box), b->use_result);
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

void zg_filament_chips_fill(GtkWidget *box, ZgModel *model, int selected, const char *what, GCallback clicked, gpointer data) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), child);
    size_t n = zs_app_filament_count(zg_model_core(model));
    for (size_t i = 0; i < n; i++) {
        char *color = zg_model_filament_get(model, i, "filament.color");
        char *mat = zg_model_filament_get(model, i, "filament.material");
        char num[16];
        g_snprintf(num, sizeof num, "%zu", i + 1);
        GtkWidget *chip = zg_filament_chip_new(color, num, selected == (int)i + 1);
        char *tip = g_strdup_printf("%s: filament %zu \u00b7 %s (%s)", what, i + 1, mat[0] ? mat : "filament", color);
        gtk_widget_set_tooltip_text(chip, tip);
        g_object_set_data(G_OBJECT(chip), "zg-value", GINT_TO_POINTER((int)i + 1));
        g_signal_connect(chip, "clicked", clicked, data);
        gtk_box_append(GTK_BOX(box), chip);
        g_free(tip);
        g_free(mat);
        g_free(color);
    }
    if (n < 16) {
        GtkWidget *plus = zg_filament_chip_new(NULL, "+", FALSE);
        char *tip = g_strdup_printf("Add a filament to the plate, for %s", what[0] ? what : "this");
        gtk_widget_set_tooltip_text(plus, tip);
        g_free(tip);
        g_signal_connect(plus, "clicked", clicked, data);
        gtk_box_append(GTK_BOX(box), plus);
    }
}

int zg_filament_chip_pick(GtkButton *chip, ZgModel *model) {
    int f = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(chip), "zg-value"));
    if (f >= 1) return f;
    /* "+": a new filament of the plate. */
    gint64 i = zg_model_filament_add(model);
    return i < 0 ? 0 : (int)i + 1;
}
