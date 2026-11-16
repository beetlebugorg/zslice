/* layer-range.c: see layer-range.h.
 *
 * The node tree is the tree of a vertical GtkScale:
 *   scale.vertical
 *     trough
 *       highlight
 *       slider (the bottom knob)
 *       slider (the top knob)
 * Each node is a small widget class with that CSS name. The trough places
 * its children (a GtkCustomLayout), from the values of the range.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "layer-range.h"

#include <math.h>

/* ---- the node classes ---- */

#define NODE_CLASS(Type, type, css)                                              \
    typedef struct { GtkWidget parent; } Type;                                     \
    typedef struct { GtkWidgetClass parent; } Type##Class;                         \
    G_DEFINE_TYPE(Type, type, GTK_TYPE_WIDGET)                                     \
    static void type##_init(Type *self) {}                                          \
    static void type##_dispose(GObject *o) {                                        \
        GtkWidget *child;                                                           \
        while ((child = gtk_widget_get_first_child(GTK_WIDGET(o)))) gtk_widget_unparent(child); \
        G_OBJECT_CLASS(type##_parent_class)->dispose(o);                            \
    }                                                                               \
    static void type##_class_init(Type##Class *k) {                                 \
        G_OBJECT_CLASS(k)->dispose = type##_dispose;                                \
        gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(k), css);                    \
    }

NODE_CLASS(ZgTrough, zg_trough, "trough")
NODE_CLASS(ZgHighlight, zg_highlight, "highlight")
NODE_CLASS(ZgKnob, zg_knob, "slider")

/* ---- the range ---- */

struct _ZgLayerRange {
    GtkWidget parent;
    GtkWidget *trough, *highlight, *knob_lo, *knob_hi;
    size_t count, lo, hi;
    /* The knob of a drag (0 none, 1 lo, 2 hi), and its value at the start. */
    int dragging;
    double drag_start_y;
};

G_DEFINE_TYPE(ZgLayerRange, zg_layer_range, GTK_TYPE_WIDGET)

enum { SIGNAL_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

static int knob_size(GtkWidget *knob, GtkOrientation o) {
    int min = 0, nat = 0;
    gtk_widget_measure(knob, o, -1, &min, &nat, NULL, NULL);
    return MAX(min, 1);
}

/* The y of the center of the knob for a value, in trough coordinates. The
 * knob centers go from half a knob below the top to half a knob above the
 * bottom of the trough. */
static double y_of(ZgLayerRange *r, size_t v, int height) {
    int kh = knob_size(r->knob_hi, GTK_ORIENTATION_VERTICAL);
    double span = MAX(0, height - kh);
    double f = r->count > 1 ? (double)v / (double)(r->count - 1) : 1;
    return kh / 2.0 + (1 - f) * span;
}

static size_t value_at(ZgLayerRange *r, double y, int height) {
    int kh = knob_size(r->knob_hi, GTK_ORIENTATION_VERTICAL);
    double span = MAX(1, height - kh);
    double f = 1 - (y - kh / 2.0) / span;
    f = CLAMP(f, 0, 1);
    if (r->count < 2) return 0;
    return (size_t)(f * (double)(r->count - 1) + 0.5);
}

static void place(GtkWidget *w, int x, int y, int width, int height) {
    GtkAllocation a = {x, y, width, height};
    gtk_widget_size_allocate(w, &a, -1);
}

/* The layout of the trough: the highlight from the lo knob to the hi knob,
 * and the knobs centered on the trough line (wider than the trough, as in
 * a GtkScale). */
static void trough_allocate(GtkWidget *trough, int width, int height, int baseline) {
    ZgLayerRange *r = ZG_LAYER_RANGE(gtk_widget_get_parent(trough));
    int kw = knob_size(r->knob_hi, GTK_ORIENTATION_HORIZONTAL);
    int kh = knob_size(r->knob_hi, GTK_ORIENTATION_VERTICAL);
    double ylo = y_of(r, r->lo, height), yhi = y_of(r, r->hi, height);
    place(r->highlight, 0, (int)yhi, width, MAX(0, (int)(ylo - yhi)));
    int x = (width - kw) / 2;
    place(r->knob_lo, x, (int)(ylo - kh / 2.0), kw, kh);
    place(r->knob_hi, x, (int)(yhi - kh / 2.0), kw, kh);
}

static void trough_measure(GtkWidget *trough, GtkOrientation o, int for_size, int *min, int *nat, int *min_b, int *nat_b) {
    /* The trough's own CSS size (min-width) and padding come from the
     * widget; the children do not change it. */
    *min = *nat = 0;
}

static void range_measure(GtkWidget *w, GtkOrientation o, int for_size, int *min, int *nat, int *min_b, int *nat_b) {
    ZgLayerRange *r = ZG_LAYER_RANGE(w);
    int tmin = 0, tnat = 0;
    gtk_widget_measure(r->trough, o, -1, &tmin, &tnat, NULL, NULL);
    int k = knob_size(r->knob_hi, o);
    if (o == GTK_ORIENTATION_HORIZONTAL) {
        *min = *nat = MAX(tmin, k);
    } else {
        *min = 2 * k + 8;
        *nat = MAX(*min, 200);
    }
}

static void range_allocate(GtkWidget *w, int width, int height, int baseline) {
    ZgLayerRange *r = ZG_LAYER_RANGE(w);
    int tmin = 0, tnat = 0;
    gtk_widget_measure(r->trough, GTK_ORIENTATION_HORIZONTAL, -1, &tmin, &tnat, NULL, NULL);
    int tw = MAX(tmin, 4);
    place(r->trough, (width - tw) / 2, 0, tw, height);
}

static void changed(ZgLayerRange *r) {
    gtk_widget_queue_allocate(r->trough);
    g_signal_emit(r, signals[SIGNAL_CHANGED], 0);
}

/* Moves a knob (1 lo, 2 hi). The knobs do not pass each other: the other
 * knob moves with it. */
static void move_knob(ZgLayerRange *r, int knob, long v) {
    if (r->count == 0) return;
    v = CLAMP(v, 0, (long)r->count - 1);
    size_t lo = r->lo, hi = r->hi;
    if (knob == 1) {
        lo = (size_t)v;
        if (hi < lo) hi = lo;
    } else {
        hi = (size_t)v;
        if (lo > hi) lo = hi;
    }
    if (lo == r->lo && hi == r->hi) return;
    r->lo = lo;
    r->hi = hi;
    changed(r);
}

static void set_active(ZgLayerRange *r, int knob, gboolean on) {
    GtkWidget *k = knob == 1 ? r->knob_lo : r->knob_hi;
    if (on) gtk_widget_set_state_flags(k, GTK_STATE_FLAG_ACTIVE, FALSE);
    else gtk_widget_unset_state_flags(k, GTK_STATE_FLAG_ACTIVE);
}

static double trough_y(ZgLayerRange *r, double y) {
    graphene_point_t in = GRAPHENE_POINT_INIT(0, (float)y), out;
    if (!gtk_widget_compute_point(GTK_WIDGET(r), r->trough, &in, &out)) return y;
    return out.y;
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    ZgLayerRange *r = data;
    if (r->count == 0) return;
    if (gtk_widget_get_focusable(GTK_WIDGET(r))) gtk_widget_grab_focus(GTK_WIDGET(r));
    int h = gtk_widget_get_height(r->trough);
    double ty = trough_y(r, y);
    double ylo = y_of(r, r->lo, h), yhi = y_of(r, r->hi, h);
    /* The nearer knob. With both at one place: the top knob above them,
     * the bottom knob under them. */
    if (fabs(ylo - yhi) < 1) r->dragging = ty > ylo ? 1 : 2;
    else r->dragging = fabs(ty - ylo) < fabs(ty - yhi) ? 1 : 2;
    r->drag_start_y = ty;
    set_active(r, r->dragging, TRUE);
    move_knob(r, r->dragging, (long)value_at(r, ty, h));
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    ZgLayerRange *r = data;
    if (!r->dragging) return;
    move_knob(r, r->dragging, (long)value_at(r, r->drag_start_y + dy, gtk_widget_get_height(r->trough)));
}

static void on_drag_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    ZgLayerRange *r = data;
    if (r->dragging) set_active(r, r->dragging, FALSE);
    r->dragging = 0;
}

static void on_motion(GtkEventControllerMotion *m, double x, double y, gpointer data) {
    ZgLayerRange *r = data;
    int h = gtk_widget_get_height(r->trough);
    double ty = trough_y(r, y);
    double ylo = y_of(r, r->lo, h), yhi = y_of(r, r->hi, h);
    int kh = knob_size(r->knob_hi, GTK_ORIENTATION_VERTICAL);
    gboolean on_lo = fabs(ty - ylo) <= kh / 2.0 && r->count > 1;
    gboolean on_hi = fabs(ty - yhi) <= kh / 2.0;
    if (on_hi) on_lo = FALSE;
    if (on_lo) gtk_widget_set_state_flags(r->knob_lo, GTK_STATE_FLAG_PRELIGHT, FALSE);
    else gtk_widget_unset_state_flags(r->knob_lo, GTK_STATE_FLAG_PRELIGHT);
    if (on_hi) gtk_widget_set_state_flags(r->knob_hi, GTK_STATE_FLAG_PRELIGHT, FALSE);
    else gtk_widget_unset_state_flags(r->knob_hi, GTK_STATE_FLAG_PRELIGHT);
}

static void on_leave(GtkEventControllerMotion *m, gpointer data) {
    ZgLayerRange *r = data;
    gtk_widget_unset_state_flags(r->knob_lo, GTK_STATE_FLAG_PRELIGHT);
    gtk_widget_unset_state_flags(r->knob_hi, GTK_STATE_FLAG_PRELIGHT);
}

static gboolean on_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    ZgLayerRange *r = data;
    int knob = (mods & GDK_SHIFT_MASK) ? 1 : 2;
    long v = (long)(knob == 1 ? r->lo : r->hi);
    switch (key) {
    case GDK_KEY_Up: case GDK_KEY_KP_Up: case GDK_KEY_Right: v += 1; break;
    case GDK_KEY_Down: case GDK_KEY_KP_Down: case GDK_KEY_Left: v -= 1; break;
    case GDK_KEY_Page_Up: v += 10; break;
    case GDK_KEY_Page_Down: v -= 10; break;
    case GDK_KEY_Home: v = 0; break;
    case GDK_KEY_End: v = (long)r->count - 1; break;
    default: return FALSE;
    }
    move_knob(r, knob, v);
    return TRUE;
}

static gboolean on_scroll(GtkEventControllerScroll *c, double dx, double dy, gpointer data) {
    ZgLayerRange *r = data;
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c));
    int knob = (mods & GDK_SHIFT_MASK) ? 1 : 2;
    double step = dy != 0 ? dy : dx;
    long v = (long)(knob == 1 ? r->lo : r->hi) + (step < 0 ? 1 : step > 0 ? -1 : 0);
    move_knob(r, knob, v);
    return TRUE;
}

static void zg_layer_range_dispose(GObject *o) {
    ZgLayerRange *r = ZG_LAYER_RANGE(o);
    g_clear_pointer(&r->trough, gtk_widget_unparent);
    G_OBJECT_CLASS(zg_layer_range_parent_class)->dispose(o);
}

static void zg_layer_range_class_init(ZgLayerRangeClass *k) {
    G_OBJECT_CLASS(k)->dispose = zg_layer_range_dispose;
    GtkWidgetClass *wk = GTK_WIDGET_CLASS(k);
    wk->measure = range_measure;
    wk->size_allocate = range_allocate;
    gtk_widget_class_set_css_name(wk, "scale");
    gtk_widget_class_set_accessible_role(wk, GTK_ACCESSIBLE_ROLE_SLIDER);
    signals[SIGNAL_CHANGED] = g_signal_new("changed", G_TYPE_FROM_CLASS(k), G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                           NULL, G_TYPE_NONE, 0);
}

static void zg_layer_range_init(ZgLayerRange *r) {
    GtkWidget *w = GTK_WIDGET(r);
    gtk_widget_add_css_class(w, "vertical");
    gtk_widget_set_focusable(w, TRUE);
    r->trough = g_object_new(zg_trough_get_type(), NULL);
    gtk_widget_set_layout_manager(r->trough, gtk_custom_layout_new(NULL, trough_measure, trough_allocate));
    gtk_widget_set_parent(r->trough, w);
    r->highlight = g_object_new(zg_highlight_get_type(), NULL);
    gtk_widget_set_parent(r->highlight, r->trough);
    r->knob_lo = g_object_new(zg_knob_get_type(), NULL);
    gtk_widget_set_parent(r->knob_lo, r->trough);
    r->knob_hi = g_object_new(zg_knob_get_type(), NULL);
    gtk_widget_set_parent(r->knob_hi, r->trough);

    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), r);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), r);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_drag_end), r);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(drag));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), r);
    g_signal_connect(motion, "leave", G_CALLBACK(on_leave), r);
    gtk_widget_add_controller(w, motion);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), r);
    gtk_widget_add_controller(w, keys);
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES | GTK_EVENT_CONTROLLER_SCROLL_DISCRETE);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), r);
    gtk_widget_add_controller(w, scroll);
}

GtkWidget *zg_layer_range_new(void) {
    return g_object_new(ZG_TYPE_LAYER_RANGE, NULL);
}

void zg_layer_range_set_count(ZgLayerRange *self, size_t count) {
    self->count = count;
    /* With one layer, there is no range: one knob. */
    gtk_widget_set_visible(self->knob_lo, count > 1);
    if (count == 0) {
        self->lo = self->hi = 0;
    } else {
        if (self->hi >= count) self->hi = count - 1;
        if (self->lo > self->hi) self->lo = self->hi;
    }
    gtk_widget_queue_allocate(self->trough);
}

size_t zg_layer_range_get_count(ZgLayerRange *self) {
    return self->count;
}

void zg_layer_range_set(ZgLayerRange *self, size_t lo, size_t hi) {
    if (self->count == 0) return;
    if (hi >= self->count) hi = self->count - 1;
    if (lo > hi) lo = hi;
    self->lo = lo;
    self->hi = hi;
    gtk_widget_queue_allocate(self->trough);
}

size_t zg_layer_range_get_lo(ZgLayerRange *self) {
    return self->lo;
}

size_t zg_layer_range_get_hi(ZgLayerRange *self) {
    return self->hi;
}
