/* support-tool.c: see support-tool.h.
 *
 * The tool keeps a copy of the areas of the core: their kind, z range, and
 * points. It reads them again after each change, an undo, a load of the
 * view, and a switch of the plate. During a drag the copy leads: the
 * outline follows the pointer at once, and each move goes to the core
 * with the slices held.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "support-tool.h"

#include <math.h>
#include <string.h>

#include "float.h"

/* The most points of an area (support_areas.max_points in the core). */
#define MAX_POINTS 256
/* The distance from a point or an outline that still hits it, in points. */
#define NEAR 10.0

enum { KIND_GRID = 0, KIND_TREE = 1, KIND_BLOCK = 3 };

static const struct {
    int kind;
    const char *name, *tip;
} KINDS[] = {
    {KIND_GRID, "Support grid", "Support grid: support under all of the part in this area that faces down"},
    {KIND_TREE, "Support tree", "Support tree: support under all of the part in this area that faces down"},
    {KIND_BLOCK, "Block", "No support under this area"},
};

typedef struct {
    int kind;
    double z_lo, z_hi;
    size_t n;
    double pts[3 * MAX_POINTS];
} Area;

struct ZgSupport {
    ZgModel *model;
    GtkWidget *area;
    zs_view *view;
    ZgSupportHost host;
    GArray *areas; /* Area */
    double draft[3 * MAX_POINTS];
    size_t draft_n;
    int sel;
    int kind;     /* the kind of the next area */
    gboolean see; /* the support lines are faint while the tool is on */
    gboolean on;
    gboolean shown;
    /* A message on the card until the next change, or NULL. */
    const char *note;
    /* The drag of a point: the area (-1: none) and the point. */
    int drag_area, drag_point;
    gboolean drag_moved;
    /* The app of the plate of the areas: a new plate drops the draft. */
    zs_app *core;
    /* The card. */
    GtkWidget *card, *title, *kinds[G_N_ELEMENTS(KINDS)], *see_box, *info, *del;
    gboolean filling;
    gboolean test_started;
};

static int scale_of(ZgSupport *s) {
    return gtk_widget_get_scale_factor(s->area);
}

static Area *area_at(ZgSupport *s, int i) {
    return i >= 0 && (guint)i < s->areas->len ? &g_array_index(s->areas, Area, i) : NULL;
}

/* ---- the areas of the core, and the view ---- */

static void read_areas(ZgSupport *s) {
    zs_app *core = zg_model_core(s->model);
    if (core != s->core) {
        s->core = core;
        s->draft_n = 0;
        s->sel = -1;
    }
    size_t n = core ? zs_app_support_area_count(core) : 0;
    g_array_set_size(s->areas, 0);
    for (size_t i = 0; i < n; i++) {
        Area a = {0};
        size_t count = 0;
        if (zs_app_support_area_get(core, i, &a.kind, a.pts, MAX_POINTS, &count, &a.z_lo, &a.z_hi) != ZS_OK) continue;
        a.n = MIN(count, MAX_POINTS);
        g_array_append_val(s->areas, a);
    }
    if (s->sel >= (int)s->areas->len) s->sel = -1;
}

static void update_card(ZgSupport *s);

/* The areas and the draft to the core view, and the card. */
static void show(ZgSupport *s) {
    if (s->view) {
        zs_view_support_clear(s->view);
        for (guint i = 0; i < s->areas->len; i++) {
            Area *a = area_at(s, (int)i);
            int flags = 1 | ((int)i == s->sel ? 2 : 0) | (s->on ? 4 : 0);
            zs_view_support_add(s->view, a->pts, a->n, a->kind, flags);
        }
        if (s->on && s->draft_n > 0) zs_view_support_add(s->view, s->draft, s->draft_n, s->kind, 4);
    }
    update_card(s);
    s->host.frame(s->host.data);
}

static void reload(ZgSupport *s) {
    if (s->drag_area >= 0) return;
    read_areas(s);
    show(s);
}

/* ---- the card ---- */

static void update_card(ZgSupport *s) {
    gtk_widget_set_visible(s->card, s->on && s->shown);
    if (!s->on) return;
    Area *a = area_at(s, s->sel);
    s->filling = TRUE;
    char *title = a ? g_strdup_printf("Support area %d", s->sel + 1) : g_strdup("Draw support");
    gtk_label_set_text(GTK_LABEL(s->title), title);
    g_free(title);
    int kind = a ? a->kind : s->kind;
    for (size_t k = 0; k < G_N_ELEMENTS(KINDS); k++)
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(s->kinds[k]), KINDS[k].kind == kind);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(s->see_box), s->see);
    s->filling = FALSE;
    char *info;
    if (a) {
        info = g_strdup_printf("%zu points, z %.2f to %.2f mm. Drag a point to move it.", a->n, a->z_lo, a->z_hi);
    } else if (s->note) {
        info = g_strdup(s->note);
    } else if (s->draft_n == 0) {
        info = g_strdup("Click points on the part to draw an area. The points snap to the lines; Shift: no snap. Click an outline to select its area.");
    } else if (s->draft_n < 3) {
        info = g_strdup_printf("%zu point%s. Click more points (at least 3). Backspace removes the last one; Esc stops.", s->draft_n,
                               s->draft_n == 1 ? "" : "s");
    } else {
        info = g_strdup_printf("%zu points. Click the first point, or press Enter, to close the area.", s->draft_n);
    }
    gtk_label_set_text(GTK_LABEL(s->info), info);
    g_free(info);
    gtk_widget_set_visible(s->del, a != NULL);
}

static void set_kind(ZgSupport *s, int kind) {
    s->note = NULL;
    if (s->sel >= 0) {
        zg_model_support_set_kind(s->model, (size_t)s->sel, kind);
        reload(s);
    } else {
        s->kind = kind;
        show(s);
    }
}

static gboolean remove_selected(ZgSupport *s) {
    if (s->sel < 0) return FALSE;
    int i = s->sel;
    s->sel = -1;
    zg_model_support_remove(s->model, (size_t)i);
    reload(s);
    return TRUE;
}

static void on_kind_toggled(GtkToggleButton *b, gpointer data) {
    ZgSupport *s = data;
    if (s->filling || !gtk_toggle_button_get_active(b)) return;
    set_kind(s, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-kind")));
}

static void on_see_toggled(GtkCheckButton *b, gpointer data) {
    ZgSupport *s = data;
    if (s->filling) return;
    s->see = gtk_check_button_get_active(b);
    s->host.focus(s->host.data);
}

static void on_delete(GtkButton *b, gpointer data) {
    remove_selected(data);
}

/* The card: its buttons take no focus, so the keys stay with the view. */
static void build_card(ZgSupport *s) {
    /* The tool keeps a reference: it disconnects the card at its end. */
    s->card = g_object_ref_sink(zg_card_new());
    gtk_widget_add_css_class(s->card, "zg-support-card");
    gtk_widget_set_halign(s->card, GTK_ALIGN_START);
    gtk_widget_set_valign(s->card, GTK_ALIGN_START);
    gtk_widget_set_margin_start(s->card, 64);
    gtk_widget_set_margin_top(s->card, 10);
    gtk_widget_set_size_request(s->card, 300, -1);
    s->title = gtk_label_new("Draw support");
    gtk_widget_add_css_class(s->title, "zg-card-title");
    gtk_label_set_xalign(GTK_LABEL(s->title), 0);
    gtk_box_append(GTK_BOX(s->card), s->title);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(row, "linked");
    for (size_t k = 0; k < G_N_ELEMENTS(KINDS); k++) {
        GtkWidget *b = gtk_toggle_button_new_with_label(KINDS[k].name);
        gtk_widget_set_tooltip_text(b, KINDS[k].tip);
        gtk_widget_set_focus_on_click(b, FALSE);
        gtk_widget_set_hexpand(b, TRUE);
        g_object_set_data(G_OBJECT(b), "zg-kind", GINT_TO_POINTER(KINDS[k].kind));
        if (k > 0) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(b), GTK_TOGGLE_BUTTON(s->kinds[0]));
        g_signal_connect(b, "toggled", G_CALLBACK(on_kind_toggled), s);
        s->kinds[k] = b;
        gtk_box_append(GTK_BOX(row), b);
    }
    gtk_box_append(GTK_BOX(s->card), row);
    s->see_box = gtk_check_button_new_with_label("See through the support");
    gtk_widget_set_tooltip_text(s->see_box, "Show the support lines faint while the tool is on, so the outlines of the areas show through them");
    gtk_widget_set_focus_on_click(s->see_box, FALSE);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(s->see_box), TRUE);
    g_signal_connect(s->see_box, "toggled", G_CALLBACK(on_see_toggled), s);
    gtk_box_append(GTK_BOX(s->card), s->see_box);
    s->info = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(s->info), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(s->info), 40);
    gtk_label_set_xalign(GTK_LABEL(s->info), 0);
    gtk_widget_add_css_class(s->info, "dim-label");
    gtk_widget_add_css_class(s->info, "numeric");
    gtk_box_append(GTK_BOX(s->card), s->info);
    s->del = gtk_button_new_with_label("Delete");
    gtk_widget_set_tooltip_text(s->del, "Delete this area (Delete)");
    gtk_widget_set_focus_on_click(s->del, FALSE);
    gtk_widget_set_halign(s->del, GTK_ALIGN_START);
    gtk_widget_add_css_class(s->del, "destructive-action");
    g_signal_connect(s->del, "clicked", G_CALLBACK(on_delete), s);
    gtk_box_append(GTK_BOX(s->card), s->del);
    gtk_widget_set_visible(s->card, FALSE);
}

/* ---- picks ---- */

/* The pixel (points) of a point of the world. FALSE if none. */
static gboolean pixel_of(ZgSupport *s, const double *p, double *x, double *y) {
    float qx, qy;
    if (!s->view || !zs_view_pixel_of(s->view, p[0], p[1], p[2], &qx, &qy)) return FALSE;
    int sc = scale_of(s);
    *x = qx / sc;
    *y = qy / sc;
    return TRUE;
}

/* The point of the part under x, y. snap: to the end of a line. */
static gboolean surface_point(ZgSupport *s, double x, double y, gboolean snap, double out[3]) {
    int sc = scale_of(s);
    return s->view && zs_view_surface_point(s->view, (float)(x * sc), (float)(y * sc), snap ? 1 : 0, out);
}

/* The point of an area near x, y, the selected area first. FALSE if
 * none. */
static gboolean point_at(ZgSupport *s, double x, double y, int *area, int *point) {
    for (int pass = 0; pass < 2; pass++) {
        for (guint i = 0; i < s->areas->len; i++) {
            if ((pass == 0) != ((int)i == s->sel)) continue;
            Area *a = area_at(s, (int)i);
            for (size_t j = 0; j < a->n; j++) {
                double qx, qy;
                if (pixel_of(s, &a->pts[3 * j], &qx, &qy) && hypot(qx - x, qy - y) < NEAR) {
                    *area = (int)i;
                    *point = (int)j;
                    return TRUE;
                }
            }
        }
    }
    return FALSE;
}

/* The distance from x, y to the segment a-b. */
static double seg_dist(double x, double y, double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
    double t = l2 > 0 ? CLAMP(((x - ax) * dx + (y - ay) * dy) / l2, 0, 1) : 0;
    return hypot(x - ax - t * dx, y - ay - t * dy);
}

/* The area whose outline is near x, y, or -1. */
static int outline_at(ZgSupport *s, double x, double y) {
    int best = -1;
    double best_d = NEAR;
    for (guint i = 0; i < s->areas->len; i++) {
        Area *a = area_at(s, (int)i);
        for (size_t j = 0; j < a->n; j++) {
            double ax, ay, bx, by;
            if (!pixel_of(s, &a->pts[3 * j], &ax, &ay) || !pixel_of(s, &a->pts[3 * ((j + 1) % a->n)], &bx, &by)) continue;
            double d = seg_dist(x, y, ax, ay, bx, by);
            if (d < best_d) {
                best_d = d;
                best = (int)i;
            }
        }
    }
    return best;
}

/* ---- draw ---- */

static void close_draft(ZgSupport *s) {
    if (s->draft_n < 3) return;
    gint64 i = zg_model_support_add(s->model, s->kind, s->draft, s->draft_n);
    s->draft_n = 0;
    s->note = i < 0 ? "The area needs 3 points or more, at most 256." : NULL;
    s->sel = (int)i;
    reload(s);
}

void zg_support_click(ZgSupport *s, double x, double y, gboolean shift) {
    if (!s->on || !s->view) return;
    s->note = NULL;
    /* The first point of the draft closes it. */
    if (s->draft_n >= 3) {
        double qx, qy;
        if (pixel_of(s, s->draft, &qx, &qy) && hypot(qx - x, qy - y) < NEAR) {
            close_draft(s);
            return;
        }
    }
    /* With no draft, a click on an outline selects its area. */
    if (s->draft_n == 0) {
        int i = outline_at(s, x, y);
        if (i >= 0) {
            s->sel = i;
            show(s);
            return;
        }
    }
    double p[3];
    if (!surface_point(s, x, y, !shift, p)) return;
    /* A click elsewhere ends the selection, and starts an area. */
    if (s->draft_n == 0) s->sel = -1;
    if (s->draft_n >= MAX_POINTS) {
        s->note = "An area has at most 256 points. Press Enter to close it.";
        show(s);
        return;
    }
    memcpy(&s->draft[3 * s->draft_n], p, sizeof p);
    s->draft_n++;
    show(s);
}

gboolean zg_support_key(ZgSupport *s, guint key) {
    if (!s->on) return FALSE;
    switch (key) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
        if (s->draft_n < 3) return FALSE;
        close_draft(s);
        return TRUE;
    case GDK_KEY_BackSpace:
        if (s->draft_n > 0) {
            s->draft_n--;
            s->note = NULL;
            show(s);
            return TRUE;
        }
        return remove_selected(s);
    case GDK_KEY_Delete:
    case GDK_KEY_KP_Delete: return remove_selected(s);
    case GDK_KEY_Escape:
        if (s->draft_n > 0) {
            s->draft_n = 0;
            s->note = NULL;
            show(s);
            return TRUE;
        }
        if (s->sel >= 0) {
            s->sel = -1;
            show(s);
            return TRUE;
        }
        return FALSE;
    default: return FALSE;
    }
}

/* ---- drag a point ---- */

gboolean zg_support_press(ZgSupport *s, double x, double y) {
    if (!s->on || !s->view || s->draft_n > 0) return FALSE;
    int area, point;
    if (!point_at(s, x, y, &area, &point)) return FALSE;
    s->sel = area;
    s->drag_area = area;
    s->drag_point = point;
    s->drag_moved = FALSE;
    s->note = NULL;
    /* The slices wait for the release: one slice, one history step. */
    zg_model_hold(s->model, TRUE);
    show(s);
    return TRUE;
}

void zg_support_drag(ZgSupport *s, double x, double y, gboolean shift) {
    Area *a = area_at(s, s->drag_area);
    double p[3];
    if (!a || !surface_point(s, x, y, !shift, p)) return;
    memcpy(&a->pts[3 * s->drag_point], p, sizeof p);
    a->z_lo = INFINITY;
    a->z_hi = -INFINITY;
    for (size_t j = 0; j < a->n; j++) {
        a->z_lo = MIN(a->z_lo, a->pts[3 * j + 2]);
        a->z_hi = MAX(a->z_hi, a->pts[3 * j + 2]);
    }
    s->drag_moved = TRUE;
    /* The outline follows at once; the core holds the slice. */
    zg_model_support_set(s->model, (size_t)s->drag_area, a->pts, a->n);
    show(s);
}

void zg_support_release(ZgSupport *s) {
    if (s->drag_area < 0) return;
    s->drag_area = -1;
    /* The end: the slice that waited, and the step of the drag. */
    zg_model_hold(s->model, FALSE);
    reload(s);
}

gboolean zg_support_dragging(ZgSupport *s) {
    return s->drag_area >= 0;
}

const char *zg_support_cursor(ZgSupport *s, double x, double y) {
    if (s->drag_area >= 0) return "grabbing";
    int area, point;
    return s->draft_n == 0 && point_at(s, x, y, &area, &point) ? "grab" : "crosshair";
}

/* ---- the test hook ----
 *
 * ZSLICE_SUPPORT_DO=steps: picks the Support tool 1 s after the first
 * slice, then runs one step each 600 ms, as the mouse and the keys would.
 * Steps, with ';' between them: "orbit dx dy" (turn the view), "click x y"
 * and "shift x y" (a click, with Shift: no snap), "key Name" (a key, by
 * its GDK name), "drag i j x y" (drag point j of area i to x, y), "kind k"
 * (button k of the card), "see 0" or "see 1", "undo", "redo". x, y are
 * points of the 3D view. The log gives the areas and the history after
 * each step. */

typedef struct {
    ZgSupport *s;
    char **steps;
    guint i;
    /* A drag in progress: its end, and the moves so far. */
    double x0, y0, x1, y1;
    int moves;
} TestRun;

static void test_log(ZgSupport *s, const char *step) {
    zs_app *core = zg_model_core(s->model);
    GString *t = g_string_new(NULL);
    g_string_append_printf(t, "support test: %s: %u areas", step, s->areas->len);
    for (guint i = 0; i < s->areas->len; i++) {
        Area *a = area_at(s, (int)i);
        g_string_append_printf(t, " [kind %d, %zu points, z %.2f to %.2f, at", a->kind, a->n, a->z_lo, a->z_hi);
        for (size_t j = 0; j < a->n; j++) {
            double x, y;
            if (pixel_of(s, &a->pts[3 * j], &x, &y)) g_string_append_printf(t, " %.0f,%.0f", x, y);
        }
        g_string_append(t, "]");
    }
    zs_stats st = {0};
    gboolean done = zs_app_state(core) == ZS_STATE_DONE && zs_app_stats(core, &st) == ZS_OK;
    g_string_append_printf(t, ", selected %d, draft %zu, history %u of %u, %s %.2f g", s->sel, s->draft_n,
                           zg_model_history_current(s->model) + 1, zg_model_history_count(s->model), done ? "sliced" : "slicing",
                           st.filament_g);
    g_message("%s", t->str);
    g_string_free(t, TRUE);
}

static gboolean test_step(gpointer data) {
    TestRun *r = data;
    ZgSupport *s = r->s;
    if (r->moves > 0) {
        /* A step of a drag: 10 moves, 50 ms apart. */
        double t = (11 - r->moves) / 10.0;
        zg_support_drag(s, r->x0 + (r->x1 - r->x0) * t, r->y0 + (r->y1 - r->y0) * t, FALSE);
        if (--r->moves > 0) return G_SOURCE_CONTINUE;
        zg_support_release(s);
        test_log(s, "drag");
        g_timeout_add(600, test_step, r);
        return G_SOURCE_REMOVE;
    }
    if (!r->steps[r->i]) {
        test_log(s, "end");
        g_strfreev(r->steps);
        g_free(r);
        return G_SOURCE_REMOVE;
    }
    char *step = g_strstrip(g_strdup(r->steps[r->i++]));
    char **f = g_strsplit(step, " ", 5);
    guint n = g_strv_length(f);
    double a = n > 1 ? g_ascii_strtod(f[1], NULL) : 0, b = n > 2 ? g_ascii_strtod(f[2], NULL) : 0;
    if (n == 3 && strcmp(f[0], "orbit") == 0 && s->view) {
        zs_view_orbit(s->view, (float)a, (float)b);
        s->host.frame(s->host.data);
    } else if (n == 3 && (strcmp(f[0], "click") == 0 || strcmp(f[0], "shift") == 0)) {
        zg_support_click(s, a, b, f[0][0] == 's');
    } else if (n == 2 && strcmp(f[0], "key") == 0) {
        if (!zg_support_key(s, gdk_keyval_from_name(f[1]))) g_message("support test: the tool did not use the key %s", f[1]);
    } else if (n == 5 && strcmp(f[0], "drag") == 0) {
        Area *ar = area_at(s, (int)a);
        if (ar && (size_t)b < ar->n && pixel_of(s, &ar->pts[3 * (size_t)b], &r->x0, &r->y0) && zg_support_press(s, r->x0, r->y0)) {
            r->x1 = g_ascii_strtod(f[3], NULL);
            r->y1 = g_ascii_strtod(f[4], NULL);
            r->moves = 10;
            g_strfreev(f);
            g_free(step);
            g_timeout_add(50, test_step, r);
            return G_SOURCE_REMOVE;
        }
        g_message("support test: no point %s of area %s to drag", f[2], f[1]);
    } else if (n == 2 && strcmp(f[0], "kind") == 0 && a >= 0 && a < G_N_ELEMENTS(KINDS)) {
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(s->kinds[(size_t)a]), TRUE);
    } else if (n == 2 && strcmp(f[0], "see") == 0) {
        gtk_check_button_set_active(GTK_CHECK_BUTTON(s->see_box), a != 0);
    } else if (n == 1 && strcmp(f[0], "undo") == 0) {
        zg_model_undo(s->model);
    } else if (n == 1 && strcmp(f[0], "redo") == 0) {
        zg_model_redo(s->model);
    } else {
        g_message("support test: a bad step: %s", step);
    }
    test_log(s, step);
    g_strfreev(f);
    g_free(step);
    g_timeout_add(600, test_step, r);
    return G_SOURCE_REMOVE;
}

static void test_start(ZgSupport *s) {
    const char *steps = g_getenv("ZSLICE_SUPPORT_DO");
    if (!steps || s->test_started || zs_app_state(zg_model_core(s->model)) != ZS_STATE_DONE) return;
    s->test_started = TRUE;
    zg_model_set_tool(s->model, ZG_TOOL_SUPPORT);
    /* As after a click: the keys go to the preview. */
    GtkWidget *preview = gtk_widget_get_ancestor(s->area, GTK_TYPE_OVERLAY);
    if (preview) gtk_widget_grab_focus(preview);
    TestRun *r = g_new0(TestRun, 1);
    r->s = s;
    r->steps = g_strsplit(steps, ";", -1);
    g_timeout_add(1000, test_step, r);
}

/* ---- the tool on and off ---- */

static void on_tool_changed(ZgModel *model, gpointer data) {
    ZgSupport *s = data;
    gboolean on = zg_model_tool(model) == ZG_TOOL_SUPPORT;
    if (on == s->on) return;
    s->on = on;
    if (s->view) zs_view_pick_skip_support(s->view, on ? 1 : 0);
    if (!on) {
        zg_support_release(s);
        s->draft_n = 0;
        s->sel = -1;
        s->note = NULL;
    }
    read_areas(s);
    show(s);
    s->host.focus(s->host.data);
}

/* An undo, a redo, or a switch of the plate: the areas of the core
 * again. */
static void on_areas_maybe_changed(ZgModel *model, gpointer data) {
    ZgSupport *s = data;
    reload(s);
}

ZgSupport *zg_support_new(ZgModel *model, GtkWidget *area, ZgSupportHost host) {
    ZgSupport *s = g_new0(ZgSupport, 1);
    s->model = model;
    s->area = area;
    s->host = host;
    s->areas = g_array_new(FALSE, TRUE, sizeof(Area));
    s->sel = -1;
    s->drag_area = -1;
    s->see = TRUE;
    s->kind = KIND_GRID;
    build_card(s);
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed), s);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_areas_maybe_changed), s);
    g_signal_connect(model, "plates-changed", G_CALLBACK(on_areas_maybe_changed), s);
    return s;
}

void zg_support_free(ZgSupport *s) {
    if (!s) return;
    g_signal_handlers_disconnect_by_data(s->model, s);
    for (size_t k = 0; k < G_N_ELEMENTS(KINDS); k++) g_signal_handlers_disconnect_by_data(s->kinds[k], s);
    g_signal_handlers_disconnect_by_data(s->see_box, s);
    g_signal_handlers_disconnect_by_data(s->del, s);
    g_object_unref(s->card);
    g_array_free(s->areas, TRUE);
    g_free(s);
}

void zg_support_set_view(ZgSupport *s, zs_view *view) {
    s->view = view;
    if (view) zs_view_pick_skip_support(view, s->on ? 1 : 0);
}

void zg_support_set_shown(ZgSupport *s, gboolean shown) {
    s->shown = shown;
    update_card(s);
}

GtkWidget *zg_support_card(ZgSupport *s) {
    return s->card;
}

gboolean zg_support_see_through(ZgSupport *s) {
    return s->on && s->see;
}

void zg_support_loaded(ZgSupport *s) {
    /* zs_view_load drew the areas of the core as plain outlines. During a
     * drag the copy here leads. */
    if (s->drag_area < 0) read_areas(s);
    if (s->on || s->drag_area >= 0) show(s);
    test_start(s);
}
