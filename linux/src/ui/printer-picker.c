/* printer-picker.c: see printer-picker.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "printer-picker.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "../net/discovery.h"
#include "../net/printer-link.h"
#include "../prefs/printers.h"
#include "bed-model.h"

/* The most rows of the model list. A search narrows it. */
#define MAX_ROWS 400
/* A model index for "my printer is not in the list". */
#define CUSTOM -2

typedef struct {
    ZgModel *model;
    GtkWindow *window;
    gboolean welcome;
    zs_printers *lib;
    ZgDiscovery *disc;

    GtkWidget *stack, *back, *next, *cancel, *title;
    /* Step 1. */
    GtkWidget *search, *brands, *models, *count, *found, *found_state, *rescan;
    GtkWidget *bed, *card_title, *card_sub, *facts, *pick_hint;
    ptrdiff_t brand;   /* the selected brand, -1 for all, -2 for the popular printers */
    ptrdiff_t current; /* the selected model, CUSTOM, or -1 */
    gboolean filling;
    /* The printer on the network that the user picked, or -1. */
    ptrdiff_t link;
    /* Step 2. */
    GtkWidget *bed2, *sum_title, *sum_facts;
    GtkWidget *name, *nozzle, *filament, *bx, *by, *bz, *kind, *url, *key, *key_row, *url_row, *test, *test_result;
    GtkStringList *nozzle_list;
    GCancellable *test_cancel;
    /* The flat bed texture of a model for the drawing of the plate, and
     * the model that it is for (-1: none loaded). */
    cairo_surface_t *bed_tex;
    ptrdiff_t bed_tex_model;
} Picker;

/* The kinds of the connection drop-down: the order of ZgLinkKind. */

static void picker_free(gpointer data) {
    Picker *p = data;
    if (p->test_cancel) g_cancellable_cancel(p->test_cancel);
    g_clear_object(&p->test_cancel);
    zg_discovery_free(p->disc);
    if (p->bed_tex) cairo_surface_destroy(p->bed_tex);
    if (p->lib) zs_printers_free(p->lib);
    g_object_unref(p->model);
    g_free(p);
}

static gboolean get_model(Picker *p, ptrdiff_t i, zs_printer_model *m) {
    return i >= 0 && zs_printers_model_get(p->lib, (size_t)i, m) == ZS_OK;
}

static char *text_of(int (*fn)(const zs_printers *, size_t, char *, size_t, size_t *), zs_printers *lib, size_t i) {
    size_t n = 0;
    if (fn(lib, i, NULL, 0, &n) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(n + 1);
    if (fn(lib, i, buf, n + 1, &n) != ZS_OK) buf[0] = 0;
    return buf;
}

static char *fmt_mm(double v) {
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.4g", v);
    return g_strdup(buf);
}

/* ---- the drawing of the build volume ---- */

typedef struct {
    double bx, by, bz, ox, oy;
    gboolean round, custom;
} Volume;

static Volume volume_of(Picker *p, gboolean editable) {
    Volume v = {220, 220, 250, 0, 0, FALSE, FALSE};
    zs_printer_model m;
    if (get_model(p, p->current, &m)) {
        v.bx = m.bed_x;
        v.by = m.bed_y;
        v.bz = m.height;
        v.ox = m.origin_x;
        v.oy = m.origin_y;
        v.round = m.round;
    } else if (p->current == CUSTOM) {
        v.custom = TRUE;
    }
    if (editable && p->bx) {
        v.bx = gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->bx));
        v.by = gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->by));
        v.bz = gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->bz));
        if (v.round) v.by = v.bx;
    }
    return v;
}

/* The isometric view: X to the right and down, Y (to the back) to the
 * right and up, Z up. */
static void iso(double x, double y, double z, double *sx, double *sy) {
    *sx = (x + y) * 0.866;
    *sy = (x - y) * 0.5 - z;
}

static void label_at(cairo_t *cr, double x, double y, const char *text, double align) {
    cairo_text_extents_t e;
    cairo_text_extents(cr, text, &e);
    cairo_move_to(cr, x - e.width * align - e.x_bearing, y - e.height / 2 - e.y_bearing);
    cairo_show_text(cr, text);
}

/* The flat bed texture of the current model, or NULL (see bed-model.h). */
static cairo_surface_t *bed_texture(Picker *p) {
    if (p->current < 0) return NULL;
    if (p->bed_tex_model == p->current) return p->bed_tex;
    if (p->bed_tex) cairo_surface_destroy(p->bed_tex);
    p->bed_tex = NULL;
    p->bed_tex_model = p->current;
    zs_printer_bed bed;
    if (zs_printers_bed(p->lib, (size_t)p->current, &bed) != ZS_OK || !bed.flat) return NULL;
    char *path = zg_bed_file_path(bed.texture);
    if (!path) return NULL;
    cairo_surface_t *s = cairo_image_surface_create_from_png(path);
    g_free(path);
    if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(s);
        return NULL;
    }
    return p->bed_tex = s;
}

static void draw_volume(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    Picker *p = data;
    gboolean editable = GTK_WIDGET(area) == p->bed2;
    Volume v = volume_of(p, editable);
    if (p->current == -1 && !editable) {
        GdkRGBA fg;
        gtk_widget_get_color(GTK_WIDGET(area), &fg);
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.45);
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 14);
        label_at(cr, width / 2.0, height / 2.0, "Pick a printer to see its build volume", 0.5);
        return;
    }
    GdkRGBA fg;
    gtk_widget_get_color(GTK_WIDGET(area), &fg);
    const double accent[3] = {0.21, 0.52, 0.89};
    /* The scale: the box fits with room for the labels. */
    double xs[8], ys[8];
    int k = 0;
    for (int ix = 0; ix < 2; ix++)
        for (int iy = 0; iy < 2; iy++)
            for (int iz = 0; iz < 2; iz++, k++) iso(ix * v.bx, iy * v.by, iz * v.bz, &xs[k], &ys[k]);
    double x0 = xs[0], x1 = xs[0], y0 = ys[0], y1 = ys[0];
    for (int i = 1; i < 8; i++) {
        x0 = fmin(x0, xs[i]);
        x1 = fmax(x1, xs[i]);
        y0 = fmin(y0, ys[i]);
        y1 = fmax(y1, ys[i]);
    }
    /* Room for the labels: more at the sides, for "Z 250 mm". */
    const double padx = 84, pady = 40;
    double s = fmin((width - 2 * padx) / (x1 - x0), (height - 2 * pady) / (y1 - y0));
    if (s <= 0) return;
    double cx = width / 2.0 - (x0 + x1) / 2 * s, cy = height / 2.0 - (y0 + y1) / 2 * s;
#define P(x, y, z) \
    do { \
        double _sx, _sy; \
        iso((x), (y), (z), &_sx, &_sy); \
        px = cx + _sx * s; \
        py = cy + _sy * s; \
    } while (0)
    double px, py;
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    /* The plate. */
    if (v.round) {
        double r = v.bx / 2;
        for (int i = 0; i <= 96; i++) {
            double a = i * 2 * G_PI / 96;
            P(r + r * cos(a), r + r * sin(a), 0);
            if (i == 0) cairo_move_to(cr, px, py);
            else cairo_line_to(cr, px, py);
        }
    } else {
        P(0, 0, 0);
        cairo_move_to(cr, px, py);
        P(v.bx, 0, 0);
        cairo_line_to(cr, px, py);
        P(v.bx, v.by, 0);
        cairo_line_to(cr, px, py);
        P(0, v.by, 0);
        cairo_line_to(cr, px, py);
        cairo_close_path(cr);
    }
    cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.16);
    cairo_fill_preserve(cr);
    /* The bed texture of the model on the plate: the image spans the
     * plate, its top row at the back. In the isometric view this is one
     * affine map. */
    cairo_surface_t *tex = bed_texture(p);
    if (tex) {
        double iw = cairo_image_surface_get_width(tex), ih = cairo_image_surface_get_height(tex);
        cairo_save(cr);
        cairo_clip_preserve(cr);
        cairo_matrix_t m;
        cairo_matrix_init(&m, 0.866 * s * v.bx / iw, 0.5 * s * v.bx / iw, -0.866 * s * v.by / ih, 0.5 * s * v.by / ih,
                          cx + 0.866 * s * v.by, cy - 0.5 * s * v.by);
        cairo_transform(cr, &m);
        cairo_set_source_surface(cr, tex, 0, 0);
        cairo_paint_with_alpha(cr, 0.55);
        cairo_restore(cr);
    }
    cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.9);
    cairo_set_line_width(cr, 2);
    cairo_stroke(cr);
    /* The grid on the plate: lines each 50 mm (10 mm on a small bed). */
    double step = fmax(v.bx, v.by) > 160 ? 50 : 10;
    cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.35);
    cairo_set_line_width(cr, 1);
    double r = v.bx / 2;
    for (double x = step; x < v.bx - 0.5; x += step) {
        double ya = 0, yb = v.by;
        if (v.round) {
            double d = sqrt(fmax(r * r - (x - r) * (x - r), 0));
            ya = r - d;
            yb = r + d;
        }
        P(x, ya, 0);
        cairo_move_to(cr, px, py);
        P(x, yb, 0);
        cairo_line_to(cr, px, py);
    }
    for (double y = step; y < v.by - 0.5; y += step) {
        double xa = 0, xb = v.bx;
        if (v.round) {
            double d = sqrt(fmax(r * r - (y - r) * (y - r), 0));
            xa = r - d;
            xb = r + d;
        }
        P(xa, y, 0);
        cairo_move_to(cr, px, py);
        P(xb, y, 0);
        cairo_line_to(cr, px, py);
    }
    cairo_stroke(cr);
    /* The build volume: thin lines, dashed at the back. */
    cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.55);
    cairo_set_line_width(cr, 1.2);
    if (v.round) {
        for (int i = 0; i <= 96; i++) {
            double a = i * 2 * G_PI / 96;
            P(r + r * cos(a), r + r * sin(a), v.bz);
            if (i == 0) cairo_move_to(cr, px, py);
            else cairo_line_to(cr, px, py);
        }
        cairo_stroke(cr);
        /* The sides: the points of the circle at the left and the right of
         * the view (where the screen x is lowest and highest). */
        double a1 = G_PI / 4 + G_PI, a2 = G_PI / 4;
        double as[2] = {a1, a2};
        for (int i = 0; i < 2; i++) {
            P(r + r * cos(as[i]), r + r * sin(as[i]), 0);
            cairo_move_to(cr, px, py);
            P(r + r * cos(as[i]), r + r * sin(as[i]), v.bz);
            cairo_line_to(cr, px, py);
        }
        cairo_stroke(cr);
    } else {
        /* The back edges (hidden): dashed. */
        double dash[] = {4, 4};
        cairo_set_dash(cr, dash, 2, 0);
        P(0, v.by, 0);
        cairo_move_to(cr, px, py);
        P(0, v.by, v.bz);
        cairo_line_to(cr, px, py);
        cairo_stroke(cr);
        cairo_set_dash(cr, NULL, 0, 0);
        double corners[4][2] = {{0, 0}, {v.bx, 0}, {v.bx, v.by}, {0, v.by}};
        for (int i = 0; i < 4; i++) {
            if (i == 3) continue;
            P(corners[i][0], corners[i][1], 0);
            cairo_move_to(cr, px, py);
            P(corners[i][0], corners[i][1], v.bz);
            cairo_line_to(cr, px, py);
        }
        for (int i = 0; i < 4; i++) {
            P(corners[i][0], corners[i][1], v.bz);
            if (i == 0) cairo_move_to(cr, px, py);
            else cairo_line_to(cr, px, py);
        }
        cairo_close_path(cr);
        cairo_stroke(cr);
    }
    /* The G-code origin: a dot. */
    double gx = -v.ox, gy = -v.oy;
    if (gx >= -1 && gx <= v.bx + 1 && gy >= -1 && gy <= v.by + 1) {
        P(gx, gy, 0);
        cairo_set_source_rgba(cr, 0.88, 0.11, 0.14, 0.95);
        cairo_arc(cr, px, py, 3.5, 0, 2 * G_PI);
        cairo_fill(cr);
    }
    /* The sizes. */
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 13);
    cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.85);
    char t[64];
    if (v.round) {
        g_snprintf(t, sizeof t, "Ø %.0f mm", v.bx); /* the toy font of cairo has no ⌀ */
        /* The front of the circle: the lowest point on the screen. */
        P(r + r * cos(-G_PI / 4), r + r * sin(-G_PI / 4), 0);
        label_at(cr, px, py + 16, t, 0.5);
    } else {
        g_snprintf(t, sizeof t, "X %.0f mm", v.bx);
        P(v.bx / 2, 0, 0);
        label_at(cr, px - 10, py + 16, t, 0.5);
        g_snprintf(t, sizeof t, "Y %.0f mm", v.by);
        P(v.bx, v.by / 2, 0);
        label_at(cr, px + 10, py + 14, t, 0.0);
    }
    g_snprintf(t, sizeof t, "Z %.0f mm", v.bz);
    if (v.round) P(r + r * cos(G_PI / 4 + G_PI), r + r * sin(G_PI / 4 + G_PI), v.bz / 2);
    else P(0, 0, v.bz / 2);
    label_at(cr, px - 10, py, t, 1.0);
#undef P
}

/* ---- the facts card ---- */

static void add_fact(GtkWidget *grid, int row, const char *key, const char *value) {
    GtkWidget *k = gtk_label_new(key);
    gtk_label_set_xalign(GTK_LABEL(k), 0);
    gtk_widget_set_valign(k, GTK_ALIGN_START);
    gtk_widget_add_css_class(k, "dim-label");
    GtkWidget *v = gtk_label_new(value);
    gtk_label_set_xalign(GTK_LABEL(v), 0);
    gtk_label_set_wrap(GTK_LABEL(v), TRUE);
    gtk_label_set_selectable(GTK_LABEL(v), FALSE);
    gtk_widget_set_hexpand(v, TRUE);
    gtk_grid_attach(GTK_GRID(grid), k, 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), v, 1, row, 1, 1);
}

static void clear_box(GtkWidget *w) {
    GtkWidget *c;
    while ((c = gtk_widget_get_first_child(w))) {
        if (GTK_IS_GRID(w)) gtk_grid_remove(GTK_GRID(w), c);
        else gtk_box_remove(GTK_BOX(w), c);
    }
}

static void fill_facts(Picker *p, GtkWidget *grid) {
    clear_box(grid);
    zs_printer_model m;
    int row = 0;
    gtk_widget_set_visible(grid, p->current != -1);
    if (p->current == CUSTOM) {
        add_fact(grid, row++, "Settings", "The generic printer of zslice. Enter the bed size in the next step.");
        return;
    }
    if (!get_model(p, p->current, &m)) return;
    char *s;
    if (m.round) s = g_strdup_printf("⌀ %.0f mm round bed, %.0f mm high", m.bed_x, m.height);
    else s = g_strdup_printf("%.0f × %.0f × %.0f mm", m.bed_x, m.bed_y, m.height);
    add_fact(grid, row++, "Build volume", s);
    g_free(s);
    char *nz = fmt_mm(m.nozzle);
    /* The other nozzle sizes of the model. */
    GString *others = g_string_new(NULL);
    char **sizes = g_strsplit(m.nozzles, ";", -1);
    for (int i = 0; sizes[i]; i++) {
        if (!sizes[i][0] || fabs(g_ascii_strtod(sizes[i], NULL) - m.nozzle) < 1e-6) continue;
        g_string_append_printf(others, "%s%s", others->len ? ", " : "", sizes[i]);
    }
    g_strfreev(sizes);
    s = others->len ? g_strdup_printf("%s mm (also %s)", nz, others->str) : g_strdup_printf("%s mm", nz);
    g_string_free(others, TRUE);
    add_fact(grid, row++, "Nozzle", s);
    g_free(s);
    g_free(nz);
    char *fil = fmt_mm(m.filament);
    s = g_strdup_printf("%s mm", fil);
    add_fact(grid, row++, "Filament", s);
    g_free(s);
    g_free(fil);
    add_fact(grid, row++, "Heating", m.heated_chamber ? "Heated bed and chamber" : m.heated_bed ? "Heated bed" : "No heated bed");
    s = g_strdup_printf("%s%s%s", m.firmware[0] ? m.firmware : "Marlin",
                        g_ascii_strcasecmp(m.kinematics, "corexy") == 0 ? " · CoreXY"
                        : g_ascii_strcasecmp(m.kinematics, "delta") == 0 ? " · delta"
                        : g_ascii_strcasecmp(m.kinematics, "i3") == 0 ? " · bed slinger" : "",
                        m.extruders > 1 ? " · more than one extruder (zslice uses the first)" : "");
    add_fact(grid, row++, "Firmware", s);
    g_free(s);
    if (m.max_accel > 0) {
        s = m.max_speed > 0 ? g_strdup_printf("%.0f mm/s², up to %.0f mm/s", m.max_accel, m.max_speed) : g_strdup_printf("%.0f mm/s²", m.max_accel);
        add_fact(grid, row++, "Motion", s);
        g_free(s);
    }
    add_fact(grid, row++, "Start G-code", m.has_start_gcode ? "From the printer profile" : "The start G-code of zslice (the profile uses scripts). Check it before the first print.");
    if (m.origin_x != 0 || m.origin_y != 0) add_fact(grid, row++, "Origin", "The center of the bed is X0 Y0");
    char *src = text_of(zs_printers_sources, p->lib, (size_t)p->current);
    add_fact(grid, row++, "Data from", src);
    g_free(src);
}

static void update_card(Picker *p) {
    zs_printer_model m;
    if (get_model(p, p->current, &m)) {
        gtk_label_set_text(GTK_LABEL(p->card_title), m.title);
        char *f = text_of(zs_printers_facts, p->lib, (size_t)p->current);
        gtk_label_set_text(GTK_LABEL(p->card_sub), f);
        g_free(f);
    } else if (p->current == CUSTOM) {
        gtk_label_set_text(GTK_LABEL(p->card_title), "Another printer");
        gtk_label_set_text(GTK_LABEL(p->card_sub), "Set the bed size and the nozzle yourself.");
    } else {
        gtk_label_set_text(GTK_LABEL(p->card_title), "No printer selected");
        gtk_label_set_text(GTK_LABEL(p->card_sub), "Search, or pick a brand and a model.");
    }
    fill_facts(p, p->facts);
    gtk_widget_queue_draw(p->bed);
    gtk_widget_set_sensitive(p->next, p->current != -1);
}

/* ---- the model list ---- */

static void header_func(GtkListBoxRow *row, GtkListBoxRow *before, gpointer data) {
    Picker *p = data;
    const char *h = g_object_get_data(G_OBJECT(row), "zg-group");
    const char *hb = before ? g_object_get_data(G_OBJECT(before), "zg-group") : NULL;
    if (!h || (hb && strcmp(h, hb) == 0)) {
        gtk_list_box_row_set_header(row, NULL);
        return;
    }
    (void)p;
    GtkWidget *l = gtk_label_new(h);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_add_css_class(l, "zg-pick-group");
    gtk_list_box_row_set_header(row, l);
}

static GtkWidget *model_row(Picker *p, size_t i, gboolean with_brand) {
    zs_printer_model m;
    zs_printers_model_get(p->lib, i, &m);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(box, "zg-pick-row");
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_widget_set_hexpand(texts, TRUE);
    GtkWidget *name = gtk_label_new(m.name);
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(name, "zg-pick-name");
    gtk_box_append(GTK_BOX(texts), name);
    char *sub = with_brand ? g_strdup_printf("%s · %s", m.brand, m.firmware[0] ? m.firmware : "Marlin")
                           : g_strdup_printf("%s%s", m.firmware[0] ? m.firmware : "Marlin", m.heated_chamber ? " · heated chamber" : "");
    GtkWidget *sl = gtk_label_new(sub);
    g_free(sub);
    gtk_label_set_xalign(GTK_LABEL(sl), 0);
    gtk_widget_add_css_class(sl, "dim-label");
    gtk_widget_add_css_class(sl, "caption");
    gtk_box_append(GTK_BOX(texts), sl);
    gtk_box_append(GTK_BOX(box), texts);
    char *size = m.round ? g_strdup_printf("⌀ %.0f × %.0f", m.bed_x, m.height) : g_strdup_printf("%.0f × %.0f × %.0f", m.bed_x, m.bed_y, m.height);
    GtkWidget *dims = gtk_label_new(size);
    g_free(size);
    gtk_widget_add_css_class(dims, "dim-label");
    gtk_widget_add_css_class(dims, "numeric");
    gtk_box_append(GTK_BOX(box), dims);
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "zg-model", GSIZE_TO_POINTER(i + 1));
    if (!with_brand) g_object_set_data_full(G_OBJECT(row), "zg-group", g_strdup(m.series), g_free);
    else g_object_set_data_full(G_OBJECT(row), "zg-group", NULL, NULL);
    return row;
}

static GtkWidget *custom_row(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(box, "zg-pick-row");
    GtkWidget *icon = gtk_image_new_from_icon_name("list-add-symbolic");
    gtk_box_append(GTK_BOX(box), icon);
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    GtkWidget *name = gtk_label_new("My printer is not in the list");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_widget_add_css_class(name, "zg-pick-name");
    GtkWidget *sub = gtk_label_new("Start from the generic printer, and enter its size");
    gtk_label_set_xalign(GTK_LABEL(sub), 0);
    gtk_widget_add_css_class(sub, "dim-label");
    gtk_widget_add_css_class(sub, "caption");
    gtk_box_append(GTK_BOX(texts), name);
    gtk_box_append(GTK_BOX(texts), sub);
    gtk_box_append(GTK_BOX(box), texts);
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "zg-custom", GINT_TO_POINTER(1));
    return row;
}

static void select_model_row(Picker *p) {
    for (GtkWidget *c = gtk_widget_get_first_child(p->models); c; c = gtk_widget_get_next_sibling(c)) {
        if (!GTK_IS_LIST_BOX_ROW(c)) continue;
        gsize v = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(c), "zg-model"));
        gboolean custom = g_object_get_data(G_OBJECT(c), "zg-custom") != NULL;
        if ((v > 0 && (ptrdiff_t)v - 1 == p->current) || (custom && p->current == CUSTOM)) {
            gtk_list_box_select_row(GTK_LIST_BOX(p->models), GTK_LIST_BOX_ROW(c));
            return;
        }
    }
    gtk_list_box_unselect_all(GTK_LIST_BOX(p->models));
}

static void fill_models(Picker *p) {
    p->filling = TRUE;
    gtk_list_box_remove_all(GTK_LIST_BOX(p->models));
    const char *q = gtk_editable_get_text(GTK_EDITABLE(p->search));
    uint32_t *idx = g_new(uint32_t, MAX_ROWS);
    /* "Popular" with no search: the printers that most people have. */
    size_t n = p->brand == -2 && q[0] == 0 ? zs_printers_popular(p->lib, idx, MAX_ROWS) : zs_printers_search(p->lib, q, p->brand == -2 ? -1 : p->brand, idx, MAX_ROWS);
    size_t shown = MIN(n, (size_t)MAX_ROWS);
    /* Groups by series only for one brand with no search. */
    gboolean by_series = p->brand >= 0 && q[0] == 0;
    for (size_t k = 0; k < shown; k++) gtk_list_box_append(GTK_LIST_BOX(p->models), model_row(p, idx[k], !by_series));
    gtk_list_box_append(GTK_LIST_BOX(p->models), custom_row());
    g_free(idx);
    char *c;
    if (n == 0) c = g_strdup_printf("No printer matches “%s”.", q);
    else if (shown < n) c = g_strdup_printf("%zu printers; the first %zu show. Type to narrow the list.", n, shown);
    else c = g_strdup_printf(n == 1 ? "%zu printer" : "%zu printers", n);
    gtk_label_set_text(GTK_LABEL(p->count), c);
    g_free(c);
    select_model_row(p);
    p->filling = FALSE;
}

static void on_model_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Picker *p = data;
    if (p->filling || !row) return;
    gsize v = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(row), "zg-model"));
    if (g_object_get_data(G_OBJECT(row), "zg-custom")) p->current = CUSTOM;
    else if (v > 0) p->current = (ptrdiff_t)v - 1;
    update_card(p);
}

static void go_setup(Picker *p);

static void on_model_activated(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Picker *p = data;
    on_model_selected(box, row, data);
    if (p->current != -1) go_setup(p);
}

static void on_search(GtkSearchEntry *e, gpointer data) {
    fill_models(data);
}

/* Enter in the search: the first match, and the next step. */
static void on_search_activate(GtkSearchEntry *e, gpointer data) {
    Picker *p = data;
    GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(p->models), 0);
    if (!first || g_object_get_data(G_OBJECT(first), "zg-custom")) return;
    gtk_list_box_select_row(GTK_LIST_BOX(p->models), first);
    on_model_selected(GTK_LIST_BOX(p->models), first, p);
    gtk_widget_grab_focus(GTK_WIDGET(first));
}

static void on_brand_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Picker *p = data;
    if (p->filling || !row) return;
    p->brand = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "zg-brand")) - 1;
    fill_models(p);
}

static GtkWidget *brand_row(const char *name, size_t count, int index) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(box, "zg-brand-row");
    GtkWidget *l = gtk_label_new(name);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(l, TRUE);
    char n[32];
    g_snprintf(n, sizeof n, "%zu", count);
    GtkWidget *c = gtk_label_new(n);
    gtk_widget_add_css_class(c, "dim-label");
    gtk_widget_add_css_class(c, "numeric");
    gtk_box_append(GTK_BOX(box), l);
    gtk_box_append(GTK_BOX(box), c);
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "zg-brand", GINT_TO_POINTER(index + 1));
    return row;
}

static void select_brand_row(Picker *p) {
    p->filling = TRUE;
    for (GtkWidget *c = gtk_widget_get_first_child(p->brands); c; c = gtk_widget_get_next_sibling(c)) {
        if (GTK_IS_LIST_BOX_ROW(c) && GPOINTER_TO_INT(g_object_get_data(G_OBJECT(c), "zg-brand")) - 1 == p->brand) {
            gtk_list_box_select_row(GTK_LIST_BOX(p->brands), GTK_LIST_BOX_ROW(c));
            break;
        }
    }
    p->filling = FALSE;
}

/* Scrolls the lists to their selected rows, after the layout. */
static gboolean scroll_later(gpointer data) {
    GtkWindow *window = data;
    Picker *p = g_object_get_data(G_OBJECT(window), "zg-picker");
    for (int i = 0; p && i < 2; i++) {
        GtkWidget *list = i == 0 ? p->brands : p->models;
        GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(list));
        GtkWidget *vp = gtk_widget_get_parent(list);
        if (row && vp && GTK_IS_VIEWPORT(vp)) gtk_viewport_scroll_to(GTK_VIEWPORT(vp), GTK_WIDGET(row), NULL);
    }
    g_object_unref(window);
    return G_SOURCE_REMOVE;
}

static void scroll_to_selection(Picker *p) {
    /* Once the rows have a size, and again after the list settles. */
    g_timeout_add(80, scroll_later, g_object_ref(p->window));
    g_timeout_add(400, scroll_later, g_object_ref(p->window));
}

/* Shows model i: its brand, no search, and its row. */
static void show_model(Picker *p, ptrdiff_t i) {
    zs_printer_model m;
    if (!get_model(p, i, &m)) return;
    p->current = i;
    p->brand = (ptrdiff_t)m.brand_index;
    p->filling = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(p->search), "");
    p->filling = FALSE;
    select_brand_row(p);
    fill_models(p);
    update_card(p);
    scroll_to_selection(p);
}

/* ---- the printers on the network ---- */

static const char *found_icon(int kind) {
    return kind == ZS_FOUND_MOONRAKER ? "network-server-symbolic" : "printer-network-symbolic";
}

static void on_found_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Picker *p = data;
    if (!row) return;
    ptrdiff_t i = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "zg-found")) - 1;
    zs_found_printer f;
    if (zs_discovery_get(zg_discovery_list(p->disc), (size_t)i, &f) != ZS_OK) return;
    p->link = i;
    /* The model: from the TXT record, the bed, or the name of the host. */
    const char *host = f.host;
    char *hint = g_strdup_printf("%s %s %s", f.model, f.name, host);
    ptrdiff_t m = zs_printers_match(p->lib, f.model[0] ? f.model : hint, f.bed_x, f.bed_y, f.height);
    if (m < 0 && f.model[0]) m = zs_printers_match(p->lib, hint, f.bed_x, f.bed_y, f.height);
    g_free(hint);
    char *msg;
    if (m >= 0) {
        show_model(p, m);
        zs_printer_model pm;
        get_model(p, m, &pm);
        msg = g_strdup_printf("%s at %s is a %s. Check the model, then go on.", f.kind_title, f.address, pm.title);
    } else {
        msg = g_strdup_printf("zslice connects to the %s at %s. Now pick its model.", f.kind_title, f.address);
        gtk_widget_grab_focus(p->search);
    }
    gtk_label_set_text(GTK_LABEL(p->pick_hint), msg);
    gtk_widget_set_visible(p->pick_hint, TRUE);
    g_free(msg);
}

static void on_found_changed(ZgDiscovery *d, gpointer data) {
    Picker *p = data;
    const zs_discovery *list = zg_discovery_list(d);
    size_t n = zs_discovery_count(list);
    GtkListBoxRow *sel = gtk_list_box_get_selected_row(GTK_LIST_BOX(p->found));
    int sel_i = sel ? GPOINTER_TO_INT(g_object_get_data(G_OBJECT(sel), "zg-found")) : 0;
    g_signal_handlers_block_by_func(p->found, on_found_selected, p);
    gtk_list_box_remove_all(GTK_LIST_BOX(p->found));
    for (size_t i = 0; i < n; i++) {
        zs_found_printer f;
        if (zs_discovery_get(list, i, &f) != ZS_OK) continue;
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_add_css_class(box, "zg-found-row");
        gtk_box_append(GTK_BOX(box), gtk_image_new_from_icon_name(found_icon(f.kind)));
        GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        GtkWidget *name = gtk_label_new(f.name);
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(name, "zg-pick-name");
        char *sub = g_strdup_printf("%s · %s", f.kind_title, f.address);
        GtkWidget *sl = gtk_label_new(sub);
        g_free(sub);
        gtk_label_set_xalign(GTK_LABEL(sl), 0);
        gtk_widget_add_css_class(sl, "dim-label");
        gtk_widget_add_css_class(sl, "caption");
        gtk_box_append(GTK_BOX(texts), name);
        gtk_box_append(GTK_BOX(texts), sl);
        gtk_box_append(GTK_BOX(box), texts);
        char *tip = g_strdup_printf("%s\n%s (%s)%s%s", f.url, f.host, f.kind_title, f.version[0] ? "\n" : "", f.version);
        gtk_widget_set_tooltip_text(box, tip);
        g_free(tip);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
        g_object_set_data(G_OBJECT(row), "zg-found", GINT_TO_POINTER((int)i + 1));
        gtk_list_box_append(GTK_LIST_BOX(p->found), row);
        if ((int)i + 1 == sel_i) gtk_list_box_select_row(GTK_LIST_BOX(p->found), GTK_LIST_BOX_ROW(row));
    }
    g_signal_handlers_unblock_by_func(p->found, on_found_selected, p);
    gtk_widget_set_visible(p->found, n > 0);
    /* The test hook: select printer n of the network when the search ends. */
    const char *hook = g_getenv("ZSLICE_PICKER_FOUND");
    if (hook && !zg_discovery_running(d) && !g_object_get_data(G_OBJECT(p->found), "zg-hook-done")) {
        g_object_set_data(G_OBJECT(p->found), "zg-hook-done", GINT_TO_POINTER(1));
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(p->found), atoi(hook) - 1);
        if (row) {
            gtk_list_box_select_row(GTK_LIST_BOX(p->found), row);
            if (g_strcmp0(g_getenv("ZSLICE_PICKER_STEP"), "2") == 0 && p->current != -1) go_setup(p);
        }
    }
    const char *state = zg_discovery_running(d) ? (n ? "Searching…" : "Searching the network…")
                        : n ? "" : "No printer answered. Enter its address in the next step.";
    gtk_label_set_text(GTK_LABEL(p->found_state), state);
    gtk_widget_set_visible(p->found_state, state[0] != 0);
    gtk_widget_set_sensitive(p->rescan, !zg_discovery_running(d));
}

static void on_rescan(GtkButton *b, gpointer data) {
    Picker *p = data;
    zg_discovery_restart(p->disc);
}

/* ---- step 2: set up ---- */

static void on_kind_changed(GObject *dd, GParamSpec *ps, gpointer data) {
    Picker *p = data;
    guint k = gtk_drop_down_get_selected(GTK_DROP_DOWN(p->kind));
    gboolean net = k == ZG_LINK_PRINTDECK || k == ZG_LINK_OCTOPRINT || k == ZG_LINK_MOONRAKER;
    gtk_widget_set_visible(p->url_row, net);
    gtk_widget_set_visible(p->key_row, k == ZG_LINK_PRINTDECK || k == ZG_LINK_OCTOPRINT);
    gtk_widget_set_visible(p->test, net);
    gtk_label_set_text(GTK_LABEL(p->test_result), "");
}

static void on_bed_changed(GtkSpinButton *s, gpointer data) {
    Picker *p = data;
    gtk_widget_queue_draw(p->bed2);
}

/* A test of the connection. It can end after the window closes: then the
 * cancellable is canceled, and the answer goes nowhere. */
typedef struct {
    Picker *p;
    GCancellable *cancel;
} Test;

static void on_test_info(ZgPrinterInfo *info, const char *error, gpointer data) {
    Test *t = data;
    Picker *p = t->p;
    gboolean gone = g_cancellable_is_cancelled(t->cancel);
    g_object_unref(t->cancel);
    g_free(t);
    if (gone) {
        if (info) zg_printer_info_free(info);
        return;
    }
    gtk_widget_set_sensitive(p->test, TRUE);
    if (!info) {
        char *msg = g_strdup_printf("No answer: %s", error ? error : "unknown error");
        gtk_label_set_text(GTK_LABEL(p->test_result), msg);
        gtk_widget_add_css_class(p->test_result, "error");
        g_free(msg);
        return;
    }
    gtk_widget_remove_css_class(p->test_result, "error");
    GString *s = g_string_new("Connected");
    if (info->state) g_string_append_printf(s, ": %s", info->state);
    g_string_append(s, ".");
    if (info->bed_x > 0) g_string_append_printf(s, " The printer has a bed of %.0f × %.0f mm.", info->bed_x, info->bed_y);
    gtk_label_set_text(GTK_LABEL(p->test_result), s->str);
    g_string_free(s, TRUE);
    zg_printer_info_free(info);
}

static void on_test(GtkButton *b, gpointer data) {
    Picker *p = data;
    ZgPrinter tmp = {0};
    tmp.id = "test";
    tmp.name = "test";
    tmp.kind = (ZgLinkKind)gtk_drop_down_get_selected(GTK_DROP_DOWN(p->kind));
    tmp.url = (char *)gtk_editable_get_text(GTK_EDITABLE(p->url));
    tmp.api_key = (char *)gtk_editable_get_text(GTK_EDITABLE(p->key));
    tmp.device = "";
    tmp.baud = 250000;
    if (p->test_cancel) g_cancellable_cancel(p->test_cancel);
    g_clear_object(&p->test_cancel);
    p->test_cancel = g_cancellable_new();
    gtk_label_set_text(GTK_LABEL(p->test_result), "Connecting…");
    gtk_widget_set_sensitive(p->test, FALSE);
    Test *t = g_new0(Test, 1);
    t->p = p;
    t->cancel = g_object_ref(p->test_cancel);
    zg_link_query(&tmp, p->test_cancel, on_test_info, t);
}

static void set_nozzles(Picker *p, const zs_printer_model *m) {
    guint n = g_list_model_get_n_items(G_LIST_MODEL(p->nozzle_list));
    char **items;
    if (m && m->nozzles[0]) items = g_strsplit(m->nozzles, ";", -1);
    else items = g_strsplit("0.2;0.25;0.3;0.4;0.5;0.6;0.8;1", ";", -1);
    GPtrArray *labels = g_ptr_array_new_with_free_func(g_free);
    guint sel = 0;
    double want = m ? m->nozzle : 0.4;
    for (guint i = 0; items[i]; i++) {
        g_ptr_array_add(labels, g_strdup_printf("%s mm", items[i]));
        if (fabs(g_ascii_strtod(items[i], NULL) - want) < 1e-6) sel = i;
    }
    g_ptr_array_add(labels, NULL);
    gtk_string_list_splice(p->nozzle_list, 0, n, (const char *const *)labels->pdata);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->nozzle), sel);
    g_ptr_array_free(labels, TRUE);
    g_strfreev(items);
}

static void go_setup(Picker *p) {
    if (p->current == -1) return;
    zs_printer_model m;
    gboolean have = get_model(p, p->current, &m);
    char *name = g_strdup(have ? m.title : "My printer");
    gtk_editable_set_text(GTK_EDITABLE(p->name), name);
    gtk_label_set_text(GTK_LABEL(p->sum_title), name);
    g_free(name);
    char *facts = have ? text_of(zs_printers_facts, p->lib, (size_t)p->current) : g_strdup("The generic printer of zslice");
    gtk_label_set_text(GTK_LABEL(p->sum_facts), facts);
    g_free(facts);
    set_nozzles(p, have ? &m : NULL);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->filament), have && m.filament > 2.2 ? 1 : 0);
    Volume v = volume_of(p, FALSE);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(p->bx), v.bx);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(p->by), v.by);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(p->bz), v.bz);
    gtk_widget_set_sensitive(p->by, !v.round);
    /* The connection: from the printer on the network, if one is picked. */
    zs_found_printer f;
    if (p->link >= 0 && zs_discovery_get(zg_discovery_list(p->disc), (size_t)p->link, &f) == ZS_OK) {
        ZgLinkKind k = f.kind == ZS_FOUND_PRINTDECK ? ZG_LINK_PRINTDECK : f.kind == ZS_FOUND_MOONRAKER ? ZG_LINK_MOONRAKER : ZG_LINK_OCTOPRINT;
        gtk_drop_down_set_selected(GTK_DROP_DOWN(p->kind), k);
        gtk_editable_set_text(GTK_EDITABLE(p->url), f.url);
    }
    on_kind_changed(NULL, NULL, p);
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "setup");
    gtk_widget_set_visible(p->back, TRUE);
    gtk_button_set_label(GTK_BUTTON(p->next), "Add printer");
    gtk_widget_queue_draw(p->bed2);
    gtk_widget_grab_focus(p->name);
}

static void go_choose(Picker *p) {
    gtk_stack_set_visible_child_name(GTK_STACK(p->stack), "choose");
    gtk_widget_set_visible(p->back, FALSE);
    gtk_button_set_label(GTK_BUTTON(p->next), "Next");
}

static void set_num(ZgModel *model, const char *key, double v) {
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.6g", v);
    zg_model_set(model, key, buf, NULL);
}

/* Adds the printer: the profile of the model, the changes of step 2, and
 * the connection. */
static void finish(Picker *p) {
    const char *name = gtk_editable_get_text(GTK_EDITABLE(p->name));
    if (!name[0]) name = "My printer";
    double nozzle = 0;
    GtkStringObject *nz = gtk_drop_down_get_selected_item(GTK_DROP_DOWN(p->nozzle));
    if (nz) nozzle = g_ascii_strtod(gtk_string_object_get_string(nz), NULL);
    char *text = NULL;
    if (p->current >= 0) {
        size_t n = 0;
        zs_printers_profile(p->lib, (size_t)p->current, nozzle, NULL, 0, &n);
        text = g_malloc(n + 1);
        if (zs_printers_profile(p->lib, (size_t)p->current, nozzle, text, n + 1, &n) != ZS_OK) text[0] = 0;
    } else {
        text = g_strdup("extends = \"generic\"\n");
    }
    /* The first start: the default printer becomes this printer. */
    ZgPrinter *pr;
    if (p->welcome) {
        pr = zg_printers_current();
        g_free(pr->name);
        pr->name = g_strdup(name);
    } else {
        pr = zg_printers_add(name);
    }
    pr->kind = (ZgLinkKind)gtk_drop_down_get_selected(GTK_DROP_DOWN(p->kind));
    g_free(pr->url);
    pr->url = g_strdup(gtk_editable_get_text(GTK_EDITABLE(p->url)));
    g_free(pr->api_key);
    pr->api_key = g_strdup(gtk_editable_get_text(GTK_EDITABLE(p->key)));
    zg_printers_save();
    if (!p->welcome) zg_model_use_printer(p->model, pr->id);
    GError *error = NULL;
    if (!zg_model_load_profile(p->model, ZS_GROUP_MACHINE, text, strlen(text), &error)) {
        g_warning("zslice: the profile of the printer was not loaded: %s", error->message);
        g_error_free(error);
    }
    g_free(text);
    /* The name, the nozzle, and the bed of step 2. */
    zg_model_set(p->model, "machine.name", name, NULL);
    if (nozzle > 0) set_num(p->model, "machine.nozzle_diameter", nozzle);
    set_num(p->model, "machine.bed_size_x", gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->bx)));
    set_num(p->model, "machine.bed_size_y", gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->by)));
    set_num(p->model, "machine.max_height", gtk_spin_button_get_value(GTK_SPIN_BUTTON(p->bz)));
    set_num(p->model, "filament.diameter", gtk_drop_down_get_selected(GTK_DROP_DOWN(p->filament)) == 1 ? 2.85 : 1.75);
    zg_printers_set_first_start(FALSE);
    zg_model_printers_edited(p->model);
    gtk_window_destroy(p->window);
}

static void on_next(GtkButton *b, gpointer data) {
    Picker *p = data;
    const char *page = gtk_stack_get_visible_child_name(GTK_STACK(p->stack));
    if (g_strcmp0(page, "choose") == 0) go_setup(p);
    else finish(p);
}

static void on_back(GtkButton *b, gpointer data) {
    go_choose(data);
}

static void on_cancel(GtkButton *b, gpointer data) {
    Picker *p = data;
    zg_printers_set_first_start(FALSE);
    gtk_window_destroy(p->window);
}

static gboolean on_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Picker *p = data;
    if (key == GDK_KEY_Escape) {
        if (g_strcmp0(gtk_stack_get_visible_child_name(GTK_STACK(p->stack)), "setup") == 0) go_choose(p);
        else on_cancel(NULL, p);
        return TRUE;
    }
    return FALSE;
}

/* ---- the window ---- */

static GtkWidget *section_label(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_widget_add_css_class(l, "zg-pick-section");
    return l;
}

static GtkWidget *scrolled(GtkWidget *child) {
    GtkWidget *s = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(s), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s), child);
    gtk_widget_set_vexpand(s, TRUE);
    return s;
}

static GtkWidget *build_choose(Picker *p) {
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    if (p->welcome) {
        GtkWidget *hero = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        gtk_widget_add_css_class(hero, "zg-pick-hero");
        GtkWidget *t = gtk_label_new("Welcome to zslice");
        gtk_widget_add_css_class(t, "zg-pick-hero-title");
        gtk_label_set_xalign(GTK_LABEL(t), 0);
        GtkWidget *s = gtk_label_new("Pick your printer. zslice sets up its bed, its nozzle, and its start G-code, and finds it on your network.");
        gtk_label_set_xalign(GTK_LABEL(s), 0);
        gtk_label_set_wrap(GTK_LABEL(s), TRUE);
        gtk_widget_add_css_class(s, "dim-label");
        gtk_box_append(GTK_BOX(hero), t);
        gtk_box_append(GTK_BOX(hero), s);
        gtk_box_append(GTK_BOX(page), hero);
    }
    GtkWidget *cols = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(cols, TRUE);
    gtk_box_append(GTK_BOX(page), cols);

    /* Left: the network and the brands. */
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(left, "zg-pick-side");
    gtk_widget_set_size_request(left, 230, -1);
    GtkWidget *net_head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *nl = section_label("On your network");
    gtk_widget_set_hexpand(nl, TRUE);
    p->rescan = gtk_button_new_from_icon_name("view-refresh-symbolic");
    gtk_widget_add_css_class(p->rescan, "flat");
    gtk_widget_set_tooltip_text(p->rescan, "Search the network again");
    g_signal_connect(p->rescan, "clicked", G_CALLBACK(on_rescan), p);
    gtk_box_append(GTK_BOX(net_head), nl);
    gtk_box_append(GTK_BOX(net_head), p->rescan);
    gtk_box_append(GTK_BOX(left), net_head);
    p->found = gtk_list_box_new();
    gtk_widget_add_css_class(p->found, "zg-pick-list");
    gtk_widget_add_css_class(p->found, "boxed-list");
    g_signal_connect(p->found, "row-selected", G_CALLBACK(on_found_selected), p);
    gtk_widget_set_visible(p->found, FALSE);
    gtk_box_append(GTK_BOX(left), p->found);
    p->found_state = gtk_label_new("Searching the network…");
    gtk_label_set_xalign(GTK_LABEL(p->found_state), 0);
    gtk_label_set_wrap(GTK_LABEL(p->found_state), TRUE);
    gtk_widget_add_css_class(p->found_state, "dim-label");
    gtk_widget_add_css_class(p->found_state, "caption");
    gtk_box_append(GTK_BOX(left), p->found_state);
    GtkWidget *bl = section_label("Brands");
    gtk_widget_set_margin_top(bl, 10);
    gtk_box_append(GTK_BOX(left), bl);
    p->brands = gtk_list_box_new();
    gtk_widget_add_css_class(p->brands, "zg-pick-list");
    gtk_widget_add_css_class(p->brands, "navigation-sidebar");
    uint32_t pop[64];
    size_t npop = zs_printers_popular(p->lib, pop, 64);
    if (npop > 0) gtk_list_box_append(GTK_LIST_BOX(p->brands), brand_row("Popular", npop, -2));
    gtk_list_box_append(GTK_LIST_BOX(p->brands), brand_row("All brands", zs_printers_model_count(p->lib), -1));
    for (size_t i = 0; i < zs_printers_brand_count(p->lib); i++) {
        const char *name = NULL;
        size_t first = 0, end = 0;
        zs_printers_brand_get(p->lib, i, &name, &first, &end);
        gtk_list_box_append(GTK_LIST_BOX(p->brands), brand_row(name, end - first, (int)i));
    }
    g_signal_connect(p->brands, "row-selected", G_CALLBACK(on_brand_selected), p);
    gtk_box_append(GTK_BOX(left), scrolled(p->brands));
    gtk_box_append(GTK_BOX(cols), left);
    gtk_box_append(GTK_BOX(cols), gtk_separator_new(GTK_ORIENTATION_VERTICAL));

    /* Middle: the search and the models. */
    GtkWidget *mid = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(mid, "zg-pick-mid");
    gtk_widget_set_size_request(mid, 340, -1);
    p->search = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(p->search), "Search 1000+ printers: “ender 3”, “mk4”, “voron”");
    g_signal_connect(p->search, "search-changed", G_CALLBACK(on_search), p);
    g_signal_connect(p->search, "activate", G_CALLBACK(on_search_activate), p);
    gtk_box_append(GTK_BOX(mid), p->search);
    p->count = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->count), 0);
    gtk_widget_add_css_class(p->count, "dim-label");
    gtk_widget_add_css_class(p->count, "caption");
    gtk_box_append(GTK_BOX(mid), p->count);
    p->models = gtk_list_box_new();
    gtk_widget_add_css_class(p->models, "zg-pick-list");
    gtk_widget_add_css_class(p->models, "navigation-sidebar");
    gtk_list_box_set_header_func(GTK_LIST_BOX(p->models), header_func, p, NULL);
    g_signal_connect(p->models, "row-selected", G_CALLBACK(on_model_selected), p);
    g_signal_connect(p->models, "row-activated", G_CALLBACK(on_model_activated), p);
    gtk_box_append(GTK_BOX(mid), scrolled(p->models));
    gtk_box_append(GTK_BOX(cols), mid);
    gtk_box_append(GTK_BOX(cols), gtk_separator_new(GTK_ORIENTATION_VERTICAL));

    /* Right: the drawing and the facts. */
    GtkWidget *right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(right, "zg-pick-card");
    gtk_widget_set_hexpand(right, TRUE);
    p->card_title = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->card_title), 0);
    gtk_label_set_wrap(GTK_LABEL(p->card_title), TRUE);
    gtk_widget_add_css_class(p->card_title, "zg-pick-title");
    p->card_sub = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->card_sub), 0);
    gtk_label_set_wrap(GTK_LABEL(p->card_sub), TRUE);
    gtk_widget_add_css_class(p->card_sub, "dim-label");
    p->bed = gtk_drawing_area_new();
    gtk_widget_set_size_request(p->bed, 320, 200);
    gtk_widget_set_vexpand(p->bed, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(p->bed), draw_volume, p, NULL);
    p->facts = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(p->facts), 6);
    gtk_grid_set_column_spacing(GTK_GRID(p->facts), 14);
    gtk_widget_add_css_class(p->facts, "zg-pick-facts");
    p->pick_hint = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->pick_hint), 0);
    gtk_label_set_wrap(GTK_LABEL(p->pick_hint), TRUE);
    gtk_widget_add_css_class(p->pick_hint, "zg-pick-hint");
    gtk_widget_set_visible(p->pick_hint, FALSE);
    gtk_box_append(GTK_BOX(right), p->card_title);
    gtk_box_append(GTK_BOX(right), p->card_sub);
    gtk_box_append(GTK_BOX(right), p->bed);
    gtk_box_append(GTK_BOX(right), p->facts);
    gtk_box_append(GTK_BOX(right), p->pick_hint);
    gtk_box_append(GTK_BOX(cols), right);
    return page;
}

static GtkWidget *form_label(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 1);
    gtk_widget_add_css_class(l, "dim-label");
    return l;
}

static GtkWidget *spin(Picker *p, double max) {
    GtkWidget *s = gtk_spin_button_new_with_range(10, max, 1);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(s), 0);
    gtk_widget_set_size_request(s, 90, -1);
    g_signal_connect(s, "value-changed", G_CALLBACK(on_bed_changed), p);
    return s;
}

static GtkWidget *build_setup(Picker *p) {
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    /* Left: the printer. */
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(left, "zg-pick-card");
    gtk_widget_set_hexpand(left, TRUE);
    p->sum_title = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->sum_title), 0);
    gtk_label_set_wrap(GTK_LABEL(p->sum_title), TRUE);
    gtk_widget_add_css_class(p->sum_title, "zg-pick-title");
    p->sum_facts = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->sum_facts), 0);
    gtk_label_set_wrap(GTK_LABEL(p->sum_facts), TRUE);
    gtk_widget_add_css_class(p->sum_facts, "dim-label");
    p->bed2 = gtk_drawing_area_new();
    gtk_widget_set_size_request(p->bed2, 320, 240);
    gtk_widget_set_vexpand(p->bed2, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(p->bed2), draw_volume, p, NULL);
    gtk_box_append(GTK_BOX(left), p->sum_title);
    gtk_box_append(GTK_BOX(left), p->sum_facts);
    gtk_box_append(GTK_BOX(left), p->bed2);
    gtk_box_append(GTK_BOX(page), left);
    gtk_box_append(GTK_BOX(page), gtk_separator_new(GTK_ORIENTATION_VERTICAL));

    /* Right: the form. */
    GtkWidget *grid = gtk_grid_new();
    gtk_widget_add_css_class(grid, "zg-pick-form");
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_widget_set_size_request(grid, 440, -1);
    int r = 0;
    gtk_grid_attach(GTK_GRID(grid), section_label("Printer"), 0, r++, 2, 1);
    p->name = gtk_entry_new();
    gtk_widget_set_hexpand(p->name, TRUE);
    gtk_grid_attach(GTK_GRID(grid), form_label("Name"), 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->name, 1, r++, 1, 1);
    p->nozzle_list = gtk_string_list_new(NULL);
    p->nozzle = gtk_drop_down_new(G_LIST_MODEL(p->nozzle_list), NULL);
    gtk_grid_attach(GTK_GRID(grid), form_label("Nozzle"), 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->nozzle, 1, r++, 1, 1);
    const char *fils[] = {"1.75 mm", "2.85 mm", NULL};
    p->filament = gtk_drop_down_new_from_strings(fils);
    gtk_grid_attach(GTK_GRID(grid), form_label("Filament"), 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->filament, 1, r++, 1, 1);
    GtkWidget *bed = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    p->bx = spin(p, 2000);
    p->by = spin(p, 2000);
    p->bz = spin(p, 2000);
    gtk_box_append(GTK_BOX(bed), p->bx);
    gtk_box_append(GTK_BOX(bed), gtk_label_new("×"));
    gtk_box_append(GTK_BOX(bed), p->by);
    gtk_box_append(GTK_BOX(bed), gtk_label_new("×"));
    gtk_box_append(GTK_BOX(bed), p->bz);
    gtk_box_append(GTK_BOX(bed), gtk_label_new("mm"));
    gtk_grid_attach(GTK_GRID(grid), form_label("Build volume"), 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), bed, 1, r++, 1, 1);
    GtkWidget *bed_note = gtk_label_new("Change the size only if your printer differs from the profile.");
    gtk_label_set_xalign(GTK_LABEL(bed_note), 0);
    gtk_label_set_wrap(GTK_LABEL(bed_note), TRUE);
    gtk_widget_add_css_class(bed_note, "dim-label");
    gtk_widget_add_css_class(bed_note, "caption");
    gtk_grid_attach(GTK_GRID(grid), bed_note, 1, r++, 1, 1);

    GtkWidget *cl = section_label("Connection");
    gtk_widget_set_margin_top(cl, 12);
    gtk_grid_attach(GTK_GRID(grid), cl, 0, r++, 2, 1);
    p->kind = gtk_drop_down_new_from_strings((const char *const *)zg_link_titles);
    g_signal_connect(p->kind, "notify::selected", G_CALLBACK(on_kind_changed), p);
    gtk_grid_attach(GTK_GRID(grid), form_label("Send to"), 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->kind, 1, r++, 1, 1);
    p->url = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->url), "http://printer.local");
    p->url_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(p->url, TRUE);
    gtk_box_append(GTK_BOX(p->url_row), p->url);
    GtkWidget *ul = form_label("Address");
    gtk_grid_attach(GTK_GRID(grid), ul, 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->url_row, 1, r++, 1, 1);
    g_object_bind_property(p->url_row, "visible", ul, "visible", G_BINDING_SYNC_CREATE);
    p->key = gtk_password_entry_new();
    gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(p->key), TRUE);
    p->key_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(p->key, TRUE);
    gtk_box_append(GTK_BOX(p->key_row), p->key);
    GtkWidget *kl = form_label("API key");
    gtk_grid_attach(GTK_GRID(grid), kl, 0, r, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), p->key_row, 1, r++, 1, 1);
    g_object_bind_property(p->key_row, "visible", kl, "visible", G_BINDING_SYNC_CREATE);
    p->test = gtk_button_new_with_label("Test the connection");
    gtk_widget_set_halign(p->test, GTK_ALIGN_START);
    g_signal_connect(p->test, "clicked", G_CALLBACK(on_test), p);
    gtk_grid_attach(GTK_GRID(grid), p->test, 1, r++, 1, 1);
    p->test_result = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->test_result), 0);
    gtk_label_set_wrap(GTK_LABEL(p->test_result), TRUE);
    gtk_widget_add_css_class(p->test_result, "caption");
    gtk_grid_attach(GTK_GRID(grid), p->test_result, 1, r++, 1, 1);
    GtkWidget *later = gtk_label_new("You can change all of this later: Preferences, Printers, and the Printer settings.");
    gtk_label_set_xalign(GTK_LABEL(later), 0);
    gtk_label_set_wrap(GTK_LABEL(later), TRUE);
    gtk_widget_add_css_class(later, "dim-label");
    gtk_widget_add_css_class(later, "caption");
    gtk_widget_set_margin_top(later, 12);
    gtk_grid_attach(GTK_GRID(grid), later, 0, r++, 2, 1);
    gtk_box_append(GTK_BOX(page), grid);
    return page;
}

void zg_printer_picker_show(GtkWindow *parent, ZgModel *model, gboolean welcome) {
    Picker *p = g_new0(Picker, 1);
    p->model = g_object_ref(model);
    p->welcome = welcome;
    /* A beginner starts with the popular printers. */
    p->brand = -2;
    p->current = -1;
    p->link = -1;
    p->bed_tex_model = -1;
    if (zs_printers_builtin(&p->lib) != ZS_OK) {
        g_warning("zslice: the printer library did not load");
        g_object_unref(p->model);
        g_free(p);
        return;
    }
    p->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(p->window, welcome ? "Welcome to zslice" : "Add a printer");
    gtk_window_set_transient_for(p->window, parent);
    gtk_window_set_modal(p->window, TRUE);
    gtk_window_set_default_size(p->window, 1100, 700);
    gtk_widget_add_css_class(GTK_WIDGET(p->window), "zg-picker");
    g_object_set_data_full(G_OBJECT(p->window), "zg-picker", p, picker_free);

    GtkWidget *header = gtk_header_bar_new();
    gtk_header_bar_set_show_title_buttons(GTK_HEADER_BAR(header), FALSE);
    p->cancel = gtk_button_new_with_label(welcome ? "Skip" : "Cancel");
    if (welcome) gtk_widget_set_tooltip_text(p->cancel, "Use the generic printer. Add your printer later from the printer menu.");
    g_signal_connect(p->cancel, "clicked", G_CALLBACK(on_cancel), p);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), p->cancel);
    p->back = gtk_button_new_from_icon_name("go-previous-symbolic");
    gtk_widget_set_tooltip_text(p->back, "Back to the list");
    gtk_widget_set_visible(p->back, FALSE);
    g_signal_connect(p->back, "clicked", G_CALLBACK(on_back), p);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), p->back);
    p->next = gtk_button_new_with_label("Next");
    gtk_widget_add_css_class(p->next, "suggested-action");
    gtk_widget_set_sensitive(p->next, FALSE);
    g_signal_connect(p->next, "clicked", G_CALLBACK(on_next), p);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), p->next);
    p->title = gtk_label_new(welcome ? "Set up your printer" : "Add a printer");
    gtk_widget_add_css_class(p->title, "title");
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), p->title);
    gtk_window_set_titlebar(p->window, header);

    p->stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(p->stack), GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);
    gtk_stack_add_named(GTK_STACK(p->stack), build_choose(p), "choose");
    gtk_stack_add_named(GTK_STACK(p->stack), build_setup(p), "setup");
    gtk_window_set_child(p->window, p->stack);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), p);
    gtk_widget_add_controller(GTK_WIDGET(p->window), keys);

    select_brand_row(p);
    fill_models(p);
    update_card(p);
    p->disc = zg_discovery_new(on_found_changed, p);
    if (p->disc) on_found_changed(p->disc, p);
    gtk_window_present(p->window);
    gtk_widget_grab_focus(p->search);

    /* The test hooks. */
    const char *q = g_getenv("ZSLICE_PICKER_QUERY");
    if (q) gtk_editable_set_text(GTK_EDITABLE(p->search), q);
    const char *id = g_getenv("ZSLICE_PICKER_MODEL");
    if (id) {
        ptrdiff_t i = zs_printers_find(p->lib, id);
        if (i >= 0) {
            if (q) {
                fill_models(p);
                p->current = i;
                select_model_row(p);
                update_card(p);
            } else {
                show_model(p, i);
            }
        }
    }
    const char *step = g_getenv("ZSLICE_PICKER_STEP");
    if ((g_strcmp0(step, "2") == 0 || g_strcmp0(step, "add") == 0) && p->current != -1) go_setup(p);
    if (g_strcmp0(step, "add") == 0 && p->current != -1) finish(p);
}

static gboolean startup_later(gpointer data) {
    GtkWindow *parent = data;
    ZgModel *model = g_object_get_data(G_OBJECT(parent), "zg-picker-model");
    if (model) zg_printer_picker_show(parent, model, zg_printers_first_start());
    return G_SOURCE_REMOVE;
}

void zg_printer_picker_startup(GtkWindow *parent, ZgModel *model) {
    if (!g_getenv("ZSLICE_PICKER") && !zg_printers_first_start()) return;
    g_object_set_data_full(G_OBJECT(parent), "zg-picker-model", g_object_ref(model), g_object_unref);
    g_timeout_add(400, startup_later, parent);
}
