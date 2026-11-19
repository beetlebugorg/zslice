/* float.c: see float.h.
 *
 * The overlay asks each child for its place ("get-child-position"). A
 * card with a place gets its natural size at that point, moved in so
 * that it stays inside the overlay.
 *
 * A drag of the head reads the pointer in the frame of the overlay: the
 * head moves with the card, so its own frame moves during the drag.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "float.h"

#include <math.h>

typedef struct {
    gboolean set;
    double x, y;
    gboolean moved; /* the user moved it */
    /* A drag: the point of the press in the card. */
    double grab_x, grab_y;
    ZgFloatMoved on_moved;
    gpointer data;
} Place;

static Place *place_of(GtkWidget *card) {
    Place *p = g_object_get_data(G_OBJECT(card), "zg-float");
    if (!p) {
        p = g_new0(Place, 1);
        g_object_set_data_full(G_OBJECT(card), "zg-float", p, g_free);
    }
    return p;
}

static gboolean on_child_position(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *alloc, gpointer data) {
    Place *p = g_object_get_data(G_OBJECT(child), "zg-float");
    if (!p || !p->set) return FALSE;
    int W = gtk_widget_get_width(GTK_WIDGET(overlay)), H = gtk_widget_get_height(GTK_WIDGET(overlay));
    int min_w = 0, nat_w = 0, min_h = 0, nat_h = 0;
    gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &min_w, &nat_w, NULL, NULL);
    int w = MAX(min_w, MIN(nat_w, W));
    gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, w, &min_h, &nat_h, NULL, NULL);
    int h = MAX(min_h, MIN(nat_h, H));
    /* The card stays inside the overlay; its head stays in it at least. */
    double x = CLAMP(p->x, 0, MAX(0, W - w));
    double y = CLAMP(p->y, 0, MAX(0, H - MIN(h, 40)));
    if (y + h > H) y = MAX(0, H - h);
    alloc->x = (int)round(x);
    alloc->y = (int)round(y);
    alloc->width = w;
    alloc->height = h;
    return TRUE;
}

void zg_float_install(GtkWidget *overlay) {
    g_signal_connect(overlay, "get-child-position", G_CALLBACK(on_child_position), NULL);
}

GtkWidget *zg_card_new(void) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(card, "zg-card");
    g_object_set_data(G_OBJECT(card), "zg-card", GINT_TO_POINTER(1));
    return card;
}

gboolean zg_float_in_card(GtkWidget *widget) {
    for (GtkWidget *w = widget; w; w = gtk_widget_get_parent(w)) {
        if (g_object_get_data(G_OBJECT(w), "zg-card")) return TRUE;
    }
    return FALSE;
}

void zg_float_place(GtkWidget *card, double x, double y) {
    Place *p = place_of(card);
    p->set = TRUE;
    p->x = x;
    p->y = y;
    GtkWidget *parent = gtk_widget_get_parent(card);
    if (parent) gtk_widget_queue_allocate(parent);
}

void zg_float_unplace(GtkWidget *card) {
    Place *p = place_of(card);
    p->set = FALSE;
    p->moved = FALSE;
    GtkWidget *parent = gtk_widget_get_parent(card);
    if (parent) gtk_widget_queue_allocate(parent);
}

gboolean zg_float_get(GtkWidget *card, double *x, double *y) {
    Place *p = g_object_get_data(G_OBJECT(card), "zg-float");
    if (!p || !p->set) return FALSE;
    if (x) *x = p->x;
    if (y) *y = p->y;
    return TRUE;
}

gboolean zg_float_user_moved(GtkWidget *card) {
    Place *p = g_object_get_data(G_OBJECT(card), "zg-float");
    return p && p->moved;
}

void zg_float_forget(GtkWidget *card) {
    Place *p = g_object_get_data(G_OBJECT(card), "zg-float");
    if (p) p->moved = FALSE;
}

/* The point of the gesture in the frame of the overlay. */
static gboolean pointer_in_overlay(GtkGesture *g, GtkWidget *card, double *ox, double *oy) {
    GtkWidget *handle = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    GtkWidget *overlay = gtk_widget_get_parent(card);
    double x, y;
    if (!overlay || !gtk_gesture_get_point(g, gtk_gesture_get_last_updated_sequence(g), &x, &y)) return FALSE;
    graphene_point_t out;
    if (!gtk_widget_compute_point(handle, overlay, &GRAPHENE_POINT_INIT((float)x, (float)y), &out)) return FALSE;
    *ox = out.x;
    *oy = out.y;
    return TRUE;
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    GtkWidget *card = data;
    Place *p = place_of(card);
    GtkWidget *overlay = gtk_widget_get_parent(card);
    graphene_point_t at;
    if (!overlay || !gtk_widget_compute_point(card, overlay, &GRAPHENE_POINT_INIT(0, 0), &at)) return;
    double px, py;
    if (!pointer_in_overlay(GTK_GESTURE(g), card, &px, &py)) return;
    p->grab_x = px - at.x;
    p->grab_y = py - at.y;
    gtk_widget_add_css_class(card, "zg-card-moving");
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    GtkWidget *card = data;
    Place *p = place_of(card);
    double px, py;
    if (fabs(dx) < 2 && fabs(dy) < 2 && !p->moved) return;
    if (!pointer_in_overlay(GTK_GESTURE(g), card, &px, &py)) return;
    GtkWidget *overlay = gtk_widget_get_parent(card);
    int W = gtk_widget_get_width(overlay), H = gtk_widget_get_height(overlay);
    double x = CLAMP(px - p->grab_x, 0, MAX(0, W - gtk_widget_get_width(card)));
    double y = CLAMP(py - p->grab_y, 0, MAX(0, H - 40));
    p->moved = TRUE;
    zg_float_place(card, x, y);
    if (p->on_moved) p->on_moved(card, x, y, p->data);
}

static void on_drag_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    gtk_widget_remove_css_class(GTK_WIDGET(data), "zg-card-moving");
}

void zg_float_movable(GtkWidget *card, GtkWidget *handle, ZgFloatMoved moved, gpointer data) {
    Place *p = place_of(card);
    p->on_moved = moved;
    p->data = data;
    GtkGesture *drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), card);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), card);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_drag_end), card);
    gtk_widget_add_controller(handle, GTK_EVENT_CONTROLLER(drag));
    gtk_widget_set_cursor_from_name(handle, "grab");
    gtk_widget_add_css_class(handle, "zg-card-handle");
}

GtkWidget *zg_card_head(GtkWidget *card, GtkWidget **head_out, GtkWidget *extra, GCallback on_close, gpointer data) {
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(head, "zg-card-head");
    GtkWidget *title = gtk_label_new("");
    gtk_widget_add_css_class(title, "zg-card-title");
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    gtk_label_set_wrap(GTK_LABEL(title), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(title), PANGO_WRAP_WORD);
    gtk_widget_set_hexpand(title, TRUE);
    gtk_box_append(GTK_BOX(head), title);
    if (extra) gtk_box_append(GTK_BOX(head), extra);
    if (on_close) {
        GtkWidget *close = gtk_button_new_from_icon_name("window-close-symbolic");
        gtk_widget_add_css_class(close, "flat");
        gtk_widget_add_css_class(close, "circular");
        gtk_widget_add_css_class(close, "zg-card-close");
        gtk_widget_set_tooltip_text(close, "Close (Esc)");
        gtk_widget_set_valign(close, GTK_ALIGN_CENTER);
        g_signal_connect(close, "clicked", on_close, data);
        gtk_box_append(GTK_BOX(head), close);
    }
    gtk_box_append(GTK_BOX(card), head);
    if (head_out) *head_out = head;
    return title;
}

/* The gap between a card and the thing that it is about. */
#define PLACE_GAP 16

void zg_place_beside(const double box[4], const double area[4], double w, double h, double *x, double *y) {
    double mid_y = (box[1] + box[3]) / 2 - h / 2, mid_x = (box[0] + box[2]) / 2 - w / 2;
    double cx = CLAMP(mid_x, area[0], MAX(area[0], area[2] - w)), cy = CLAMP(mid_y, area[1], MAX(area[1], area[3] - h));
    const double room[4] = {area[2] - (box[2] + PLACE_GAP), box[0] - PLACE_GAP - area[0], area[3] - (box[3] + PLACE_GAP),
                            box[1] - PLACE_GAP - area[1]};
    const double need[4] = {w, w, h, h};
    const double at[4][2] = {{box[2] + PLACE_GAP, cy}, {box[0] - PLACE_GAP - w, cy}, {cx, box[3] + PLACE_GAP}, {cx, box[1] - PLACE_GAP - h}};
    int side = -1;
    for (int k = 0; k < 4 && side < 0; k++)
        if (room[k] >= need[k]) side = k;
    if (side < 0) {
        /* No side has the room: the side with the most, in the area. */
        side = 0;
        for (int k = 1; k < 4; k++)
            if (room[k] / need[k] > room[side] / need[side]) side = k;
    }
    *x = CLAMP(at[side][0], area[0], MAX(area[0], area[2] - w));
    *y = CLAMP(at[side][1], area[1], MAX(area[1], area[3] - h));
}

void zg_free_area(GtkWidget *host, double area[4]) {
    area[0] = 62;
    area[1] = 8;
    area[2] = gtk_widget_get_width(host) - 60;
    area[3] = gtk_widget_get_height(host) - 82;
}
