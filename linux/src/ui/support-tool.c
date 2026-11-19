/* support-tool.c: see support-tool.h.
 *
 * The tool keeps a copy of the areas of the core: their kind, z range, and
 * points. It reads them again after each change, an undo, a load of the
 * view, and a switch of the plate. During a drag the copy leads: the
 * outline follows the pointer at once, and each move goes to the core
 * with the slices held.
 *
 * Trees (tree support): the nodes of the trees show as dots. A click on a
 * dot or a segment selects its branch. A drag of a dot moves the node, a
 * drag of the ring of the selected node makes the branch wider or narrower
 * there, and a drag of a segment moves the branch. Delete removes the
 * branch (and the branches over it). "Add a branch": a tap on the bed (the
 * foot), then on the place of the part that needs support. "Reset support"
 * plans the trees of the part again. The core keeps each edit within the
 * rules (zs_app_support_tree_*); an edit that a rule limited shows red.
 * During a drag the dots follow the pointer at once; the core gets the
 * edit at most each 60 ms, with the slice held, and the release sends the
 * last edit.
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
/* The kind of the view for a tree that a rule limited: red. */
#define KIND_RED 3
/* The flags of zs_view_support_add. */
enum { CLOSED = 1, SELECTED = 2, POINTS = 4, BARE = 8 };
/* The smallest distance on the screen between two dots that the view
 * draws (points): more dots add no help. */
#define DOT_CELL 7.0
/* The clamp bits (enum zs_tree_clamp), in words. */
static const struct {
    uint32_t bit;
    const char *text;
} CLAMP_TEXT[] = {
    {ZS_TREE_CLAMP_PART, "it stays out of the part"},
    {ZS_TREE_CLAMP_LEAN, "a segment leans at most the tree angle"},
    {ZS_TREE_CLAMP_RADIUS_MIN, "the rules need this width"},
    {ZS_TREE_CLAMP_RADIUS_MAX, "this is the largest width"},
    {ZS_TREE_CLAMP_REACH, "the foot moved nearer, so the branch can reach the tip"},
};

/* The trees of a part. */
typedef struct {
    size_t part;
    gboolean edited;
    GArray *nodes; /* zs_tree_node */
} Tree;

/* The drag of a tree element. */
enum { TD_NONE = 0, TD_NODE, TD_RING, TD_SEG };

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
    /* The overhang under the pointer (zs_app_support_pick): its outline
     * and z range. A click puts support under it. */
    gboolean hot;
    size_t hot_n;
    double hot_pts[3 * MAX_POINTS], hot_lo, hot_hi;
    /* The app of the plate of the areas: a new plate drops the draft. */
    zs_app *core;
    /* The card. */
    GtkWidget *card, *title, *kinds[G_N_ELEMENTS(KINDS)], *see_box, *info, *del;
    /* The trees (Tree, by part), the selected node (tsel_part -1: none),
     * the rules that limited the last edit, and "Add a branch" (adding;
     * has_foot: the foot is on the bed). */
    GPtrArray *trees;
    zs_app *trees_core; /* the app of the plate of the trees */
    gint64 tsel_part;
    guint32 tsel_node;
    guint32 tclamp;
    gboolean adding, has_foot;
    double foot[2];
    /* The drag of a tree element: its kind, part, and node, the height of
     * its plane, the start point on it, the nodes that move and their
     * places at the start, the move that the core applied (a branch), the
     * move or radius that the pointer wants, and the time of the last
     * edit sent (60 ms apart). */
    int td;
    size_t td_part;
    guint32 td_node;
    double td_z, td_start[2], td_applied[2], want_r, want_dx, want_dy;
    GArray *td_branch; /* guint32 */
    GArray *td_orig;   /* double x, y */
    gboolean td_moved, td_dirty;
    gint64 td_sent;
    guint td_timer;
    /* The card of the trees: Add a branch, Reset support, Delete branch,
     * and the text. */
    GtkWidget *tree_row, *tree_add, *tree_reset, *tree_info, *tree_del;
    char *tree_note;
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

/* ---- the support trees ---- */

static void tree_free(gpointer data) {
    Tree *t = data;
    g_array_free(t->nodes, TRUE);
    g_free(t);
}

static Tree *tree_of(ZgSupport *s, size_t part) {
    for (guint i = 0; i < s->trees->len; i++) {
        Tree *t = g_ptr_array_index(s->trees, i);
        if (t->part == part) return t;
    }
    return NULL;
}

static zs_tree_node *node_of(ZgSupport *s, size_t part, guint32 i) {
    Tree *t = tree_of(s, part);
    return t && i < t->nodes->len ? &g_array_index(t->nodes, zs_tree_node, i) : NULL;
}

static gboolean tsel_ok(ZgSupport *s) {
    return s->tsel_part >= 0 && node_of(s, (size_t)s->tsel_part, s->tsel_node) != NULL;
}

/* The trees of part `part` from the core (none with no nodes). While a
 * slice runs, the core has none to give: the last ones stay. */
static void read_tree(ZgSupport *s, size_t part) {
    zs_app *core = zg_model_core(s->model);
    ptrdiff_t n = core ? zs_app_support_tree_nodes(core, part, NULL, 0) : 0;
    Tree *t = tree_of(s, part);
    if (n < 0) return;
    if (n == 0) {
        if (t) g_ptr_array_remove(s->trees, t);
        return;
    }
    if (!t) {
        t = g_new0(Tree, 1);
        t->part = part;
        t->nodes = g_array_new(FALSE, TRUE, sizeof(zs_tree_node));
        g_ptr_array_add(s->trees, t);
    }
    g_array_set_size(t->nodes, (guint)n);
    ptrdiff_t got = zs_app_support_tree_nodes(core, part, (zs_tree_node *)(void *)t->nodes->data, (size_t)n);
    g_array_set_size(t->nodes, got < 0 ? 0 : (guint)MIN(got, n));
    t->edited = zs_app_support_tree_edited(core, part) == 1;
}

/* The trees of each part, after a slice or an undo (only while the tool is
 * on: the trees cost a little to read). */
static void read_trees(ZgSupport *s) {
    zs_app *core = zg_model_core(s->model);
    if (s->td) return;
    if (!s->on || !core || core != s->trees_core) g_ptr_array_set_size(s->trees, 0);
    s->trees_core = core;
    if (!s->on || !core) return;
    size_t parts = zs_app_part_count(core);
    for (guint i = s->trees->len; i-- > 0;)
        if (((Tree *)g_ptr_array_index(s->trees, i))->part >= parts) g_ptr_array_remove_index(s->trees, i);
    for (size_t i = 0; i < parts; i++) read_tree(s, i);
    char note[512];
    if (zs_app_support_tree_note(core, note, sizeof note) > 0) {
        g_free(s->tree_note);
        s->tree_note = g_strdup(note);
    }
    if (!tsel_ok(s)) s->tsel_part = -1;
}

/* The nodes of the branch of node i. */
static GArray *branch_of(ZgSupport *s, size_t part, guint32 i) {
    GArray *out = g_array_new(FALSE, FALSE, sizeof(guint32));
    Tree *t = tree_of(s, part);
    zs_tree_node *nd = node_of(s, part, i);
    if (!t || !nd) return out;
    for (guint k = 0; k < t->nodes->len; k++)
        if (g_array_index(t->nodes, zs_tree_node, k).branch == nd->branch) g_array_append_val(out, k);
    return out;
}

static gboolean in_branch(GArray *b, guint32 k) {
    for (guint i = 0; i < b->len; i++)
        if (g_array_index(b, guint32, i) == k) return TRUE;
    return FALSE;
}

/* The points of the ring of a node: on its circle, at its z. */
static void ring_points(const zs_tree_node *nd, int count, double *out) {
    for (int k = 0; k < count; k++) {
        double a = 2 * G_PI * k / count;
        out[3 * k] = nd->x + nd->r * cos(a);
        out[3 * k + 1] = nd->y + nd->r * sin(a);
        out[3 * k + 2] = nd->z;
    }
}

static double seg_dist(double x, double y, double ax, double ay, double bx, double by);
static gboolean pixel_of(ZgSupport *s, const double *p, double *x, double *y);

/* The tree element under x, y: the ring of the selected node first, then
 * the dots, then the segments (node to its down node). */
static int tree_at(ZgSupport *s, double x, double y, size_t *part, guint32 *node) {
    if (s->trees->len == 0) return TD_NONE;
    double cx, cy;
    /* The ring of a thin node is near its dot: the dot wins near its
     * center. */
    if (tsel_ok(s) && !(pixel_of(s, &node_of(s, (size_t)s->tsel_part, s->tsel_node)->x, &cx, &cy) && hypot(cx - x, cy - y) < NEAR * 0.5)) {
        zs_tree_node *nd = node_of(s, (size_t)s->tsel_part, s->tsel_node);
        double ring[3 * 16];
        ring_points(nd, 16, ring);
        for (int k = 0; k < 16; k++) {
            double ax, ay, bx, by;
            if (pixel_of(s, &ring[3 * k], &ax, &ay) && pixel_of(s, &ring[3 * ((k + 1) % 16)], &bx, &by) &&
                seg_dist(x, y, ax, ay, bx, by) < NEAR * 0.7) {
                *part = (size_t)s->tsel_part;
                *node = s->tsel_node;
                return TD_RING;
            }
        }
    }
    int kind = TD_NONE;
    double best = NEAR;
    for (guint i = 0; i < s->trees->len; i++) {
        Tree *t = g_ptr_array_index(s->trees, i);
        for (guint k = 0; k < t->nodes->len; k++) {
            zs_tree_node *nd = &g_array_index(t->nodes, zs_tree_node, k);
            double qx, qy;
            if (!pixel_of(s, &nd->x, &qx, &qy)) continue;
            double d = hypot(qx - x, qy - y);
            if (d < best) {
                best = d;
                kind = TD_NODE;
                *part = t->part;
                *node = k;
            }
        }
    }
    if (kind) return kind;
    best = NEAR * 0.7;
    for (guint i = 0; i < s->trees->len; i++) {
        Tree *t = g_ptr_array_index(s->trees, i);
        for (guint k = 0; k < t->nodes->len; k++) {
            zs_tree_node *nd = &g_array_index(t->nodes, zs_tree_node, k);
            if (nd->down < 0 || (guint)nd->down >= t->nodes->len) continue;
            zs_tree_node *dn = &g_array_index(t->nodes, zs_tree_node, nd->down);
            double ax, ay, bx, by;
            if (!pixel_of(s, &nd->x, &ax, &ay) || !pixel_of(s, &dn->x, &bx, &by)) continue;
            double d = seg_dist(x, y, ax, ay, bx, by);
            if (d < best) {
                best = d;
                kind = TD_SEG;
                *part = t->part;
                *node = k;
            }
        }
    }
    return kind;
}

/* Dots: at most 256 to a call of the view. */
static void add_dots(ZgSupport *s, GArray *pts, int kind, int flags) {
    for (guint i = 0; i < pts->len / 3; i += 256)
        zs_view_support_add(s->view, &g_array_index(pts, double, 3 * i), MIN(256, pts->len / 3 - i), kind, BARE | POINTS | flags);
}

/* The trees to the core view: a dot for each node (one dot for nodes
 * closer than DOT_CELL on the screen), the segments of the selected
 * branch and into it, the ring of the selected node, and the foot of a
 * new branch. */
static void show_trees(ZgSupport *s) {
    if (!s->on || !s->view) return;
    int kind = s->tclamp ? KIND_RED : KIND_TREE;
    GArray *branch = NULL;
    if (tsel_ok(s)) {
        size_t part = (size_t)s->tsel_part;
        Tree *t = tree_of(s, part);
        branch = branch_of(s, part, s->tsel_node);
        for (guint k = 0; k < t->nodes->len; k++) {
            zs_tree_node *nd = &g_array_index(t->nodes, zs_tree_node, k);
            if (nd->down < 0 || (guint)nd->down >= t->nodes->len) continue;
            gboolean inb = in_branch(branch, k);
            if (!inb && !in_branch(branch, (guint32)nd->down)) continue;
            zs_tree_node *dn = &g_array_index(t->nodes, zs_tree_node, nd->down);
            double seg[6] = {nd->x, nd->y, nd->z, dn->x, dn->y, dn->z};
            zs_view_support_add(s->view, seg, 2, kind, BARE | (inb ? SELECTED : 0));
        }
        GArray *dots = g_array_new(FALSE, FALSE, sizeof(double));
        for (guint i = 0; i < branch->len; i++) {
            guint32 k = g_array_index(branch, guint32, i);
            if (k == s->tsel_node) continue;
            g_array_append_vals(dots, &g_array_index(t->nodes, zs_tree_node, k).x, 3);
        }
        add_dots(s, dots, kind, 0);
        g_array_free(dots, TRUE);
        zs_tree_node *sn = node_of(s, part, s->tsel_node);
        zs_view_support_add(s->view, &sn->x, 1, kind, BARE | POINTS | SELECTED);
        double ring[3 * 24];
        ring_points(sn, 24, ring);
        zs_view_support_add(s->view, ring, 24, kind, BARE | CLOSED | SELECTED);
    }
    GHashTable *seen = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, NULL);
    GArray *dots = g_array_new(FALSE, FALSE, sizeof(double));
    for (guint i = 0; i < s->trees->len; i++) {
        Tree *t = g_ptr_array_index(s->trees, i);
        for (guint k = 0; k < t->nodes->len; k++) {
            if (branch && (gint64)t->part == s->tsel_part && in_branch(branch, k)) continue;
            zs_tree_node *nd = &g_array_index(t->nodes, zs_tree_node, k);
            double qx, qy;
            if (!pixel_of(s, &nd->x, &qx, &qy)) continue;
            gint64 key = (gint64)floor(qx / DOT_CELL) * 65536 + (gint64)floor(qy / DOT_CELL);
            if (g_hash_table_contains(seen, &key)) continue;
            g_hash_table_add(seen, g_memdup2(&key, sizeof key));
            g_array_append_vals(dots, &nd->x, 3);
        }
    }
    add_dots(s, dots, KIND_TREE, 0);
    g_array_free(dots, TRUE);
    g_hash_table_destroy(seen);
    if (branch) g_array_free(branch, TRUE);
    if (s->adding && s->has_foot) {
        double f[3] = {s->foot[0], s->foot[1], 0};
        zs_view_support_add(s->view, f, 1, KIND_TREE, BARE | POINTS | SELECTED);
    }
}

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
        if (s->on && s->hot && s->draft_n == 0) zs_view_support_add(s->view, s->hot_pts, s->hot_n, s->kind, 1 | 2 | 4);
        show_trees(s);
    }
    update_card(s);
    s->host.frame(s->host.data);
}

static void reload(ZgSupport *s) {
    if (s->drag_area >= 0 || s->td) return;
    read_areas(s);
    read_trees(s);
    show(s);
}

/* ---- the card ---- */

static void update_tree_card(ZgSupport *s);

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
    update_tree_card(s);
    char *info;
    if (a) {
        info = g_strdup_printf("%zu points, z %.2f to %.2f mm. Drag a point to move it.", a->n, a->z_lo, a->z_hi);
    } else if (s->note) {
        info = g_strdup(s->note);
    } else if (s->adding || tsel_ok(s)) {
        info = NULL;
    } else if (s->draft_n == 0) {
        info = g_strdup("Point at an overhang: it lights up, and a click puts support under it. Alt and a click draw an area point by point (Shift: no snap). Click an outline to select its area.");
    } else if (s->draft_n < 3) {
        info = g_strdup_printf("%zu point%s. Click more points (at least 3). Backspace removes the last one; Esc stops.", s->draft_n,
                               s->draft_n == 1 ? "" : "s");
    } else {
        info = g_strdup_printf("%zu points. Click the first point, or press Enter, to close the area.", s->draft_n);
    }
    gtk_label_set_text(GTK_LABEL(s->info), info ? info : "");
    gtk_widget_set_visible(s->info, info != NULL);
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

static void on_tree_add(GtkToggleButton *b, gpointer data);
static void on_tree_reset(GtkButton *b, gpointer data);
static void on_tree_delete(GtkButton *b, gpointer data);

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
    /* The trees: Add a branch, Reset support, the text, Delete branch. */
    s->tree_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(s->tree_row, "linked");
    s->tree_add = gtk_toggle_button_new_with_label("Add a branch");
    gtk_widget_set_tooltip_text(s->tree_add, "Tap a spot on the bed, then the place on the part that needs support");
    gtk_widget_set_focus_on_click(s->tree_add, FALSE);
    gtk_widget_set_hexpand(s->tree_add, TRUE);
    g_signal_connect(s->tree_add, "toggled", G_CALLBACK(on_tree_add), s);
    s->tree_reset = gtk_button_new_with_label("Reset support");
    gtk_widget_set_tooltip_text(s->tree_reset, "Plan the support trees of this part again");
    gtk_widget_set_focus_on_click(s->tree_reset, FALSE);
    gtk_widget_set_hexpand(s->tree_reset, TRUE);
    g_signal_connect(s->tree_reset, "clicked", G_CALLBACK(on_tree_reset), s);
    gtk_box_append(GTK_BOX(s->tree_row), s->tree_add);
    gtk_box_append(GTK_BOX(s->tree_row), s->tree_reset);
    gtk_widget_set_margin_top(s->tree_row, 6);
    gtk_box_append(GTK_BOX(s->card), s->tree_row);
    s->tree_info = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(s->tree_info), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(s->tree_info), 40);
    gtk_label_set_xalign(GTK_LABEL(s->tree_info), 0);
    gtk_widget_add_css_class(s->tree_info, "dim-label");
    gtk_widget_add_css_class(s->tree_info, "numeric");
    gtk_box_append(GTK_BOX(s->card), s->tree_info);
    s->tree_del = gtk_button_new_with_label("Delete branch");
    gtk_widget_set_tooltip_text(s->tree_del, "Delete this branch and the branches over it (Delete)");
    gtk_widget_set_focus_on_click(s->tree_del, FALSE);
    gtk_widget_set_halign(s->tree_del, GTK_ALIGN_START);
    gtk_widget_add_css_class(s->tree_del, "destructive-action");
    g_signal_connect(s->tree_del, "clicked", G_CALLBACK(on_tree_delete), s);
    gtk_box_append(GTK_BOX(s->card), s->tree_del);
    s->del = gtk_button_new_with_label("Delete");
    gtk_widget_set_tooltip_text(s->del, "Delete this area (Delete)");
    gtk_widget_set_focus_on_click(s->del, FALSE);
    gtk_widget_set_halign(s->del, GTK_ALIGN_START);
    gtk_widget_add_css_class(s->del, "destructive-action");
    g_signal_connect(s->del, "clicked", G_CALLBACK(on_delete), s);
    gtk_box_append(GTK_BOX(s->card), s->del);
    gtk_widget_set_visible(s->card, FALSE);
}

/* ---- the card of the trees, and the edits ---- */

static void update_tree_card(ZgSupport *s) {
    gboolean any = s->trees->len > 0 || s->adding;
    gtk_widget_set_visible(s->tree_row, any);
    gtk_widget_set_visible(s->tree_info, any);
    gtk_widget_set_visible(s->tree_del, any && tsel_ok(s));
    if (!any) return;
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(s->tree_add), s->adding);
    /* Reset: the part of the selection, else the one part with edits. */
    gint64 part = tsel_ok(s) ? s->tsel_part : -1;
    if (part < 0) {
        int edited = 0;
        for (guint i = 0; i < s->trees->len; i++) {
            Tree *t = g_ptr_array_index(s->trees, i);
            if (t->edited) {
                edited++;
                part = (gint64)t->part;
            }
        }
        if (edited != 1) part = -1;
    }
    Tree *pt = part >= 0 ? tree_of(s, (size_t)part) : NULL;
    gtk_widget_set_visible(s->tree_reset, pt && pt->edited);
    g_object_set_data(G_OBJECT(s->tree_reset), "zg-part", GINT_TO_POINTER((int)part));
    GString *text = g_string_new(NULL);
    if (s->tree_note) g_string_append_printf(text, "%s ", s->tree_note);
    if (s->adding) {
        g_string_append(text, s->has_foot ? "Now tap the place on the part that needs support. Esc stops."
                                          : "Tap a spot on the bed for the foot of the branch. Esc stops.");
    } else if (tsel_ok(s)) {
        zs_tree_node *nd = node_of(s, (size_t)s->tsel_part, s->tsel_node);
        GArray *b = branch_of(s, (size_t)s->tsel_part, s->tsel_node);
        g_string_append_printf(text, "Branch: %u node%s. This node: %.1f mm wide (at least %.1f mm), z %.2f mm. Drag a dot to move it, the ring to make it wider or narrower, a segment to move the branch. Delete removes the branch.",
                               b->len, b->len == 1 ? "" : "s", 2 * nd->r, 2 * nd->r_min, nd->z);
        g_array_free(b, TRUE);
    } else {
        g_string_append(text, "Click a dot or a segment of a tree to select its branch.");
    }
    if (s->tclamp) {
        g_string_append(text, " Limited: ");
        gboolean first = TRUE;
        for (size_t k = 0; k < G_N_ELEMENTS(CLAMP_TEXT); k++) {
            if (!(s->tclamp & CLAMP_TEXT[k].bit)) continue;
            g_string_append_printf(text, "%s%s", first ? "" : "; ", CLAMP_TEXT[k].text);
            first = FALSE;
        }
        g_string_append(text, ".");
        gtk_widget_add_css_class(s->tree_info, "warning");
    } else {
        gtk_widget_remove_css_class(s->tree_info, "warning");
    }
    gtk_label_set_text(GTK_LABEL(s->tree_info), text->str);
    g_string_free(text, TRUE);
}

/* The result of an edit of the core: the trees of the part again, the
 * clamp bits, and a slice. done: the core made the edit. */
static void tree_done(ZgSupport *s, size_t part, gboolean done, int rc, guint32 clamp) {
    s->tclamp = clamp;
    g_clear_pointer(&s->tree_note, g_free);
    if (!done) s->note = rc == -ZS_BUSY || rc == ZS_BUSY ? "Slice first: the edits of the trees need a slice." : "The trees cannot change like that.";
    else zg_model_support_trees_changed(s->model);
    read_tree(s, part);
    if (!tsel_ok(s)) s->tsel_part = -1;
}

static gboolean delete_branch(ZgSupport *s) {
    if (!tsel_ok(s)) return FALSE;
    size_t part = (size_t)s->tsel_part;
    ptrdiff_t n = zs_app_support_tree_delete_branch(zg_model_core(s->model), part, s->tsel_node);
    s->tsel_part = -1;
    tree_done(s, part, n >= 0, (int)n, 0);
    show(s);
    return TRUE;
}

static void on_tree_delete(GtkButton *b, gpointer data) {
    delete_branch(data);
}

static void on_tree_reset(GtkButton *b, gpointer data) {
    ZgSupport *s = data;
    int part = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "zg-part"));
    if (part < 0) return;
    s->tsel_part = -1;
    gboolean done = zs_app_support_tree_reset(zg_model_core(s->model), (size_t)part) == 1;
    tree_done(s, (size_t)part, TRUE, 0, 0);
    if (!done) read_tree(s, (size_t)part);
    show(s);
}

static void on_tree_add(GtkToggleButton *b, gpointer data) {
    ZgSupport *s = data;
    if (s->filling || gtk_toggle_button_get_active(b) == s->adding) return;
    s->adding = gtk_toggle_button_get_active(b);
    s->has_foot = FALSE;
    s->tsel_part = -1;
    s->note = NULL;
    show(s);
}

static gboolean surface_point(ZgSupport *s, double x, double y, gboolean snap, double out[3]);

/* "Add a branch": a tap on the bed (the foot), then a tap on the part. */
static void add_click(ZgSupport *s, double x, double y) {
    int sc = scale_of(s);
    if (!s->has_foot) {
        if (!zs_view_bed_point(s->view, (float)(x * sc), (float)(y * sc), &s->foot[0], &s->foot[1])) return;
        s->has_foot = TRUE;
        show(s);
        return;
    }
    double t[3];
    if (!surface_point(s, x, y, FALSE, t)) {
        s->note = "Tap the place on the part that needs support.";
        show(s);
        return;
    }
    s->adding = FALSE;
    zs_app *core = zg_model_core(s->model);
    ptrdiff_t part = zs_app_part_at(core, t[0], t[1]);
    if (part < 0) {
        s->note = "No room for a branch there: tap under an overhang, higher than the bed.";
        show(s);
        return;
    }
    guint32 clamp = 0;
    ptrdiff_t tip = zs_app_support_tree_add_branch(core, (size_t)part, s->foot[0], s->foot[1], t[0], t[1], t[2], &clamp);
    tree_done(s, (size_t)part, tip >= 0, (int)tip, clamp);
    if (tip >= 0) {
        s->tsel_part = part;
        s->tsel_node = (guint32)tip;
    } else {
        s->note = "No room for a branch there: tap under an overhang, higher than the bed.";
    }
    show(s);
}

/* ---- drag a node, a ring, or a branch ---- */

/* The point of the level plane at height z under x, y. */
static gboolean plane_point(ZgSupport *s, double x, double y, double z, double out[2]) {
    int sc = scale_of(s);
    return s->view && zs_view_plane_point(s->view, (float)(x * sc), (float)(y * sc), z, &out[0], &out[1]);
}

static gboolean tree_press(ZgSupport *s, double x, double y) {
    size_t part = 0;
    guint32 node = 0;
    int kind = tree_at(s, x, y, &part, &node);
    if (!kind) return FALSE;
    zs_tree_node *nd = node_of(s, part, node);
    /* A segment: the branch moves with the point of the plane at the
     * height of the middle of the segment. */
    double z = nd->z;
    if (kind == TD_SEG && nd->down >= 0) z = (nd->z + node_of(s, part, (guint32)nd->down)->z) / 2;
    if (!plane_point(s, x, y, z, s->td_start)) return FALSE;
    g_array_set_size(s->td_branch, 0);
    if (kind == TD_SEG) {
        GArray *b = branch_of(s, part, node);
        g_array_append_vals(s->td_branch, b->data, b->len);
        g_array_free(b, TRUE);
    } else {
        g_array_append_val(s->td_branch, node);
    }
    g_array_set_size(s->td_orig, 0);
    for (guint i = 0; i < s->td_branch->len; i++) {
        zs_tree_node *q = node_of(s, part, g_array_index(s->td_branch, guint32, i));
        g_array_append_val(s->td_orig, q->x);
        g_array_append_val(s->td_orig, q->y);
    }
    s->td = kind;
    s->td_part = part;
    s->td_node = node;
    s->td_z = z;
    s->td_applied[0] = s->td_applied[1] = 0;
    s->td_moved = s->td_dirty = FALSE;
    s->td_sent = 0;
    /* The drag selects the branch of the node. */
    s->tsel_part = (gint64)part;
    s->tsel_node = node;
    s->sel = -1;
    s->note = NULL;
    /* The slices wait for the release: one slice, one history step. */
    zg_model_hold(s->model, TRUE);
    show(s);
    return TRUE;
}

/* The local preview of the drag: the nodes follow the pointer at once;
 * the core clamps them when it gets the edit. */
static void tree_preview(ZgSupport *s) {
    Tree *t = tree_of(s, s->td_part);
    if (!t) return;
    if (s->td == TD_RING) {
        zs_tree_node *nd = node_of(s, s->td_part, s->td_node);
        if (nd) nd->r = s->want_r;
        return;
    }
    for (guint i = 0; i < s->td_branch->len; i++) {
        zs_tree_node *q = node_of(s, s->td_part, g_array_index(s->td_branch, guint32, i));
        if (!q) continue;
        q->x = g_array_index(s->td_orig, double, 2 * i) + s->want_dx;
        q->y = g_array_index(s->td_orig, double, 2 * i + 1) + s->want_dy;
    }
}

/* The edit of the drag now, to the core: TRUE if the core made it. */
static gboolean tree_send(ZgSupport *s) {
    zs_app *core = zg_model_core(s->model);
    guint32 clamp = 0;
    int rc;
    if (s->td == TD_RING) {
        rc = zs_app_support_tree_set_radius(core, s->td_part, s->td_node, s->want_r, &clamp);
    } else if (s->td == TD_NODE) {
        rc = zs_app_support_tree_move_node(core, s->td_part, s->td_node, g_array_index(s->td_orig, double, 0) + s->want_dx,
                                           g_array_index(s->td_orig, double, 1) + s->want_dy, &clamp);
    } else {
        /* A branch: the core moves it from where it is now. */
        rc = zs_app_support_tree_move_branch(core, s->td_part, s->td_node, s->want_dx - s->td_applied[0], s->want_dy - s->td_applied[1], &clamp);
    }
    s->td_dirty = FALSE;
    s->td_sent = g_get_monotonic_time();
    s->tclamp = clamp;
    if (rc != ZS_OK) return FALSE;
    zg_model_support_trees_changed(s->model);
    read_tree(s, s->td_part);
    if (s->td == TD_SEG && s->td_branch->len > 0) {
        zs_tree_node *q = node_of(s, s->td_part, g_array_index(s->td_branch, guint32, 0));
        if (q) {
            s->td_applied[0] = q->x - g_array_index(s->td_orig, double, 0);
            s->td_applied[1] = q->y - g_array_index(s->td_orig, double, 1);
        }
    }
    return TRUE;
}

static gboolean on_tree_timer(gpointer data) {
    ZgSupport *s = data;
    s->td_timer = 0;
    if (s->td && s->td_dirty) {
        tree_send(s);
        show(s);
    }
    return G_SOURCE_REMOVE;
}

static void tree_drag(ZgSupport *s, double x, double y) {
    double p[2];
    if (!plane_point(s, x, y, s->td_z, p)) return;
    s->td_moved = TRUE;
    if (s->td == TD_RING) {
        zs_tree_node *nd = node_of(s, s->td_part, s->td_node);
        if (!nd) return;
        s->want_r = MAX(0.05, hypot(p[0] - nd->x, p[1] - nd->y));
    } else {
        s->want_dx = p[0] - s->td_start[0];
        s->want_dy = p[1] - s->td_start[1];
    }
    s->td_dirty = TRUE;
    /* The core gets the edit at most each 60 ms. */
    if (g_get_monotonic_time() - s->td_sent >= 60000) tree_send(s);
    else if (!s->td_timer) s->td_timer = g_timeout_add(60, on_tree_timer, s);
    tree_preview(s);
    show(s);
}

/* The end of the drag: the last edit, then the slice that waited starts,
 * the step of the history ends, and the fall check runs (the hold). */
static void tree_release(ZgSupport *s) {
    if (!s->td) return;
    if (s->td_timer) g_source_remove(s->td_timer);
    s->td_timer = 0;
    if (s->td_moved) tree_send(s);
    s->td = TD_NONE;
    zg_model_hold(s->model, FALSE);
    read_trees(s);
    show(s);
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
    gint64 i = zg_model_support_add(s->model, s->kind, s->draft, s->draft_n, NAN, NAN);
    s->draft_n = 0;
    s->note = i < 0 ? "The area needs 3 points or more, at most 256." : NULL;
    s->sel = (int)i;
    reload(s);
}

void zg_support_click(ZgSupport *s, double x, double y, gboolean shift, gboolean alt) {
    if (!s->on || !s->view) return;
    s->note = NULL;
    if (s->adding) {
        add_click(s, x, y);
        return;
    }
    /* A dot or a segment of a tree: select its branch. */
    if (s->draft_n == 0) {
        size_t part;
        guint32 node;
        int kind = tree_at(s, x, y, &part, &node);
        if (kind == TD_NODE || kind == TD_SEG) {
            s->tsel_part = (gint64)part;
            s->tsel_node = node;
            s->tclamp = 0;
            s->sel = -1;
            show(s);
            return;
        }
        if (kind == TD_NONE && s->tsel_part >= 0) {
            s->tsel_part = -1;
            s->tclamp = 0;
        }
    }
    /* The overhang under the pointer: support under it, in one click. Alt
     * and a click draw a point. */
    if (s->draft_n == 0 && !alt && outline_at(s, x, y) < 0) {
        zg_support_hover(s, x, y);
        if (s->hot) {
            s->hot = FALSE;
            gint64 i = zg_model_support_add(s->model, s->kind, s->hot_pts, s->hot_n, s->hot_lo, s->hot_hi);
            s->sel = (int)i;
            reload(s);
            return;
        }
    }
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
        return remove_selected(s) || delete_branch(s);
    case GDK_KEY_Delete:
    case GDK_KEY_KP_Delete: return remove_selected(s) || delete_branch(s);
    case GDK_KEY_Escape:
        if (s->adding) {
            s->adding = FALSE;
            show(s);
            return TRUE;
        }
        if (s->tsel_part >= 0) {
            s->tsel_part = -1;
            s->tclamp = 0;
            show(s);
            return TRUE;
        }
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
    if (!s->on || !s->view || s->draft_n > 0 || s->adding) return FALSE;
    int area, point;
    if (!point_at(s, x, y, &area, &point)) return tree_press(s, x, y);
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
    if (s->td) {
        tree_drag(s, x, y);
        return;
    }
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
    tree_release(s);
    if (s->drag_area < 0) return;
    s->drag_area = -1;
    /* The end: the slice that waited, and the step of the drag. */
    zg_model_hold(s->model, FALSE);
    reload(s);
}

gboolean zg_support_dragging(ZgSupport *s) {
    return s->drag_area >= 0 || s->td;
}

/* The overhang under the pointer lights up: the faces that face down and
 * connect to the face under the pointer. Not while an area is drawn, or
 * over a point or an outline. */
void zg_support_hover(ZgSupport *s, double x, double y) {
    gboolean was = s->hot;
    size_t was_n = s->hot_n;
    double was_lo = s->hot_lo;
    int area, point;
    double p[3];
    s->hot = FALSE;
    size_t tp;
    guint32 tn;
    if (s->on && s->view && s->core && s->draft_n == 0 && s->drag_area < 0 && !s->td && !s->adding && !point_at(s, x, y, &area, &point) &&
        tree_at(s, x, y, &tp, &tn) == TD_NONE &&
        outline_at(s, x, y) < 0 && surface_point(s, x, y, FALSE, p)) {
        size_t n = 0;
        double lo = 0, hi = 0;
        ptrdiff_t part = zs_app_support_pick(s->core, p[0], p[1], p[2], 4, s->hot_pts, MAX_POINTS, &n, &lo, &hi);
        if (part >= 0 && n >= 3) {
            s->hot = TRUE;
            s->hot_n = n;
            s->hot_lo = lo;
            s->hot_hi = hi;
        }
    }
    if (was != s->hot || (s->hot && (was_n != s->hot_n || was_lo != s->hot_lo))) show(s);
}

const char *zg_support_cursor(ZgSupport *s, double x, double y) {
    if (s->drag_area >= 0 || s->td) return "grabbing";
    int area, point;
    size_t tp;
    guint32 tn;
    if (s->draft_n == 0 && !s->adding) {
        int kind = tree_at(s, x, y, &tp, &tn);
        if (kind == TD_RING) return "ew-resize";
        if (kind) return "grab";
    }
    return s->draft_n == 0 && point_at(s, x, y, &area, &point) ? "grab" : "crosshair";
}

/* ---- the test hook ----
 *
 * ZSLICE_SUPPORT_DO=steps: picks the Support tool 1 s after the first
 * slice, then runs one step each 600 ms, as the mouse and the keys would.
 * Steps, with ';' between them: "orbit dx dy" (turn the view), "click x y"
 * and "shift x y" (a click, with Shift: no snap), "key Name" (a key, by
 * its GDK name), "drag i j x y" (drag point j of area i to x, y), "kind k"
 * (button k of the card), "see 0" or "see 1", "undo", "redo". Trees:
 * "tclick k" (a click on node k of the first tree), "tdrag k dx dy" (drag
 * node k by dx, dy), "tseg k dx dy" (drag the segment of node k down),
 * "tring dx" (drag the ring of the selected node at its +X point by dx),
 * "tadd fx fy tx ty" (Add a branch: the foot at the pixel fx, fy, the tip
 * at tx, ty), "tdel" (Delete), "treset" (Reset support). x, y are points of
 * the 3D view. The log gives the areas, the trees, and the history after
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
    for (guint i = 0; i < s->trees->len; i++) {
        Tree *tr = g_ptr_array_index(s->trees, i);
        g_string_append_printf(t, " [tree of part %zu: %u nodes%s]", tr->part, tr->nodes->len, tr->edited ? ", edited" : "");
    }
    if (tsel_ok(s)) {
        zs_tree_node *nd = node_of(s, (size_t)s->tsel_part, s->tsel_node);
        double x = 0, y = 0;
        pixel_of(s, &nd->x, &x, &y);
        g_string_append_printf(t, ", node %u at %.2f, %.2f, %.2f (pixel %.0f,%.0f), r %.2f (min %.2f)", s->tsel_node, nd->x, nd->y, nd->z, x, y,
                               nd->r, nd->r_min);
    }
    if (s->tclamp) g_string_append_printf(t, ", clamp %u", s->tclamp);
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
        zg_support_click(s, a, b, f[0][0] == 's', FALSE);
    } else if (n == 3 && (strcmp(f[0], "alt") == 0)) {
        zg_support_click(s, a, b, FALSE, TRUE);
    } else if (n == 3 && strcmp(f[0], "hover") == 0) {
        zg_support_hover(s, a, b);
        g_message("support test: hover %s, %zu points, z %.2f to %.2f", s->hot ? "on an overhang" : "on none", s->hot ? s->hot_n : 0,
                  s->hot_lo, s->hot_hi);
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
    } else if ((n == 2 && strcmp(f[0], "tclick") == 0) || (n == 4 && (strcmp(f[0], "tdrag") == 0 || strcmp(f[0], "tseg") == 0)) ||
               (n == 2 && strcmp(f[0], "tring") == 0)) {
        Tree *tr = s->trees->len ? g_ptr_array_index(s->trees, 0) : NULL;
        zs_tree_node *nd = NULL;
        if (f[0][1] == 'r') nd = tsel_ok(s) ? node_of(s, (size_t)s->tsel_part, s->tsel_node) : NULL;
        else nd = tr && (guint)a < tr->nodes->len ? &g_array_index(tr->nodes, zs_tree_node, (guint)a) : NULL;
        double px, py;
        if (!nd) {
            g_message("support test: no node for %s", step);
        } else if (f[0][1] == 'c') {
            if (pixel_of(s, &nd->x, &px, &py)) zg_support_click(s, px, py, FALSE, FALSE);
        } else {
            double p[3] = {nd->x, nd->y, nd->z}, dx = f[0][1] == 'r' ? a : b, dy = f[0][1] == 'r' ? 0 : g_ascii_strtod(f[3], NULL);
            if (f[0][1] == 'r') p[0] += nd->r;
            if (f[0][1] == 's' && nd->down >= 0) {
                zs_tree_node *dn = &g_array_index(tr->nodes, zs_tree_node, nd->down);
                p[0] = (nd->x + dn->x) / 2;
                p[1] = (nd->y + dn->y) / 2;
                p[2] = (nd->z + dn->z) / 2;
            }
            if (pixel_of(s, p, &r->x0, &r->y0) && zg_support_press(s, r->x0, r->y0)) {
                r->x1 = r->x0 + dx;
                r->y1 = r->y0 + dy;
                r->moves = 10;
                g_strfreev(f);
                g_free(step);
                g_timeout_add(50, test_step, r);
                return G_SOURCE_REMOVE;
            }
            g_message("support test: no press for %s", step);
        }
    } else if (n == 5 && strcmp(f[0], "tadd") == 0) {
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(s->tree_add), TRUE);
        zg_support_click(s, a, b, FALSE, FALSE);
        zg_support_click(s, g_ascii_strtod(f[3], NULL), g_ascii_strtod(f[4], NULL), FALSE, FALSE);
    } else if (n == 1 && strcmp(f[0], "tdel") == 0) {
        if (!zg_support_key(s, GDK_KEY_Delete)) g_message("support test: no branch to delete");
    } else if (n == 1 && strcmp(f[0], "treset") == 0) {
        if (gtk_widget_get_visible(s->tree_reset)) g_signal_emit_by_name(s->tree_reset, "clicked");
        else g_message("support test: no Reset support");
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
        s->adding = FALSE;
        s->tsel_part = -1;
        s->tclamp = 0;
    }
    read_areas(s);
    read_trees(s);
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
    s->trees = g_ptr_array_new_with_free_func(tree_free);
    s->td_branch = g_array_new(FALSE, FALSE, sizeof(guint32));
    s->td_orig = g_array_new(FALSE, FALSE, sizeof(double));
    s->tsel_part = -1;
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
    g_signal_handlers_disconnect_by_data(s->tree_add, s);
    g_signal_handlers_disconnect_by_data(s->tree_reset, s);
    g_signal_handlers_disconnect_by_data(s->tree_del, s);
    if (s->td_timer) g_source_remove(s->td_timer);
    g_object_unref(s->card);
    g_array_free(s->areas, TRUE);
    g_ptr_array_free(s->trees, TRUE);
    g_array_free(s->td_branch, TRUE);
    g_array_free(s->td_orig, TRUE);
    g_free(s->tree_note);
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
