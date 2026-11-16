/* view3d.c: see view3d.h.
 *
 * The widget draws nothing: it is a transparent hole in the window, and the
 * core draws the 3D view with Vulkan into a native subsurface under it (see
 * native-surface.h). The widget only:
 *   - makes the subsurface and the core view when it is mapped, and frees
 *     them when it is unmapped,
 *   - moves and resizes the subsurface with the widget,
 *   - sends the drag and scroll gestures to the core,
 *   - asks the core for a frame after a change.
 *
 * Frames are drawn on demand: one idle callback for each change, so a view
 * that does not change uses no CPU.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "view3d.h"

#include <math.h>

#include "native-surface.h"

typedef struct {
    ZgModel *model;
    GtkWidget *area;
    ZgNativeSurface *native;
    zs_view *view;
    char *error;
    size_t layer;
    gboolean features;
    gboolean zoomed;
    gboolean picked;
    gboolean timed;
    gboolean have_data;
    guint idle;
    double drag_x, drag_y;
    double press_x, press_y;
} View3d;

static gboolean draw_now(gpointer data) {
    View3d *v = data;
    v->idle = 0;
    /* For development and screenshots: ZSLICE_TIME=t shows the replay at t
     * seconds, once, before the first frame with data. */
    const char *time = g_getenv("ZSLICE_TIME");
    if (time && v->view && !v->timed && zs_view_duration(v->view) > 0) {
        zs_view_set_time(v->view, g_ascii_strtod(time, NULL));
        v->timed = TRUE;
    }
    if (v->view) {
        int rc = zs_view_draw(v->view);
        if (rc != ZS_OK) g_warning("zslice: the 3D view did not draw: %s", zg_status_text(rc));
    }
    return G_SOURCE_REMOVE;
}

static void queue_frame(View3d *v) {
    if (!v->idle && v->view) v->idle = g_idle_add(draw_now, v);
}

/* The widget position in the window, in logical points. */
static gboolean widget_origin(View3d *v, int *x, int *y) {
    GtkNative *native = gtk_widget_get_native(v->area);
    if (!native) return FALSE;
    graphene_point_t p;
    if (!gtk_widget_compute_point(v->area, GTK_WIDGET(native), &GRAPHENE_POINT_INIT(0, 0), &p)) return FALSE;
    double nx = 0, ny = 0;
    gtk_native_get_surface_transform(native, &nx, &ny);
    *x = (int)round(p.x + nx);
    *y = (int)round(p.y + ny);
    return TRUE;
}

static void sync_geometry(View3d *v) {
    if (!v->native) return;
    int x, y;
    if (!widget_origin(v, &x, &y)) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    zg_native_surface_move(v->native, x, y, scale);
    int w = gtk_widget_get_width(v->area), h = gtk_widget_get_height(v->area);
    if (v->view) zs_view_resize(v->view, (uint32_t)MAX(1, w * scale), (uint32_t)MAX(1, h * scale));
    queue_frame(v);
}

static void load_data(View3d *v) {
    if (!v->view) return;
    zs_view_set_mode(v->view, v->features ? ZS_VIEW_FEATURES : ZS_VIEW_PRINT);
    int rc = zs_view_load(v->view, zg_model_core(v->model));
    if (rc != ZS_OK) {
        g_warning("zslice: the 3D view did not load the toolpaths: %s", zg_status_text(rc));
        return;
    }
    zs_view_set_layer(v->view, v->layer);
    gint64 sel = zg_model_selected(v->model);
    zs_view_highlight(v->view, sel < 0 ? (size_t)-1 : (size_t)sel);
    /* For development and screenshots: ZSLICE_ZOOM=0.3 starts nearer. */
    const char *zoom = g_getenv("ZSLICE_ZOOM");
    if (zoom && !v->zoomed && zs_app_layer_count(zg_model_core(v->model)) > 0) {
        zs_view_zoom(v->view, (float)g_ascii_strtod(zoom, NULL));
        v->zoomed = TRUE;
    }
    /* For development and screenshots: ZSLICE_PICK=x,y picks the path at
     * that pixel (logical points) after the first load. */
    const char *pick = g_getenv("ZSLICE_PICK");
    if (pick && !v->picked && zs_app_layer_count(zg_model_core(v->model)) > 0) {
        char **xy = g_strsplit(pick, ",", 2);
        if (xy[0] && xy[1]) {
            int scale = gtk_widget_get_scale_factor(v->area);
            /* The preview sets the layer after the load: pick on all layers. */
            v->layer = zs_app_layer_count(zg_model_core(v->model)) - 1;
            zs_view_set_layer(v->view, v->layer);
            size_t path = zs_view_pick(v->view, (float)(g_ascii_strtod(xy[0], NULL) * scale), (float)(g_ascii_strtod(xy[1], NULL) * scale));
            v->picked = TRUE;
            if (path != (size_t)-1) zg_model_select(v->model, (gint64)path);
        }
        g_strfreev(xy);
    }
    queue_frame(v);
}

void zg_view3d_set_feature_colors(GtkWidget *view, gboolean features) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    v->features = features;
    load_data(v);
}

static void on_map(GtkWidget *w, gpointer data) {
    View3d *v = data;
    if (v->view) return;
    GtkNative *native = gtk_widget_get_native(w);
    if (!native) return;
    int x = 0, y = 0;
    widget_origin(v, &x, &y);
    int scale = gtk_widget_get_scale_factor(w);
    GError *error = NULL;
    v->native = zg_native_surface_new(gtk_native_get_surface(native), x, y, scale, &error);
    if (!v->native) {
        g_free(v->error);
        v->error = g_strdup(error->message);
        g_error_free(error);
        gtk_widget_queue_draw(w);
        return;
    }
    int width = MAX(1, gtk_widget_get_width(w) * scale), height = MAX(1, gtk_widget_get_height(w) * scale);
    int rc = zs_view_new(zg_native_surface_handle(v->native), (uint32_t)width, (uint32_t)height, &v->view);
    if (rc != ZS_OK) {
        g_free(v->error);
        v->error = g_strdup_printf("the 3D view did not start: %s", zg_status_text(rc));
        zg_native_surface_free(v->native);
        v->native = NULL;
        v->view = NULL;
        gtk_widget_queue_draw(w);
        return;
    }
    load_data(v);
    sync_geometry(v);
}

static void on_unmap(GtkWidget *w, gpointer data) {
    View3d *v = data;
    if (v->idle) {
        g_source_remove(v->idle);
        v->idle = 0;
    }
    if (v->view) zs_view_free(v->view);
    v->view = NULL;
    if (v->native) {
        zg_native_surface_hide(v->native);
        zg_native_surface_free(v->native);
    }
    v->native = NULL;
}

static void on_resize(GtkDrawingArea *area, int width, int height, gpointer data) {
    sync_geometry(data);
}

/* Draws only a message if the view could not start. Otherwise the widget
 * stays transparent. */
static void draw_message(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    View3d *v = data;
    if (!v->error) return;
    cairo_set_source_rgb(cr, 0.965, 0.969, 0.973);
    cairo_paint(cr);
    cairo_set_source_rgb(cr, 0.45, 0.48, 0.52);
    cairo_set_font_size(cr, 15);
    cairo_text_extents_t ext;
    cairo_text_extents(cr, v->error, &ext);
    cairo_move_to(cr, (w - ext.width) / 2, h / 2.0);
    cairo_show_text(cr, v->error);
}

void zg_view3d_reload(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    load_data(v);
}

void zg_view3d_set_time(GtkWidget *view, double t) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v->view) return;
    zs_view_set_time(v->view, t);
    queue_frame(v);
}

double zg_view3d_duration(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v->view ? zs_view_duration(v->view) : 0;
}

size_t zg_view3d_layer_at_time(GtkWidget *view, double t) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v->view ? zs_view_layer_at_time(v->view, t) : 0;
}

void zg_view3d_set_layer(GtkWidget *view, size_t layer) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    v->layer = layer;
    if (v->view) zs_view_set_layer(v->view, layer);

    queue_frame(v);
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    View3d *v = data;
    v->drag_x = 0;
    v->drag_y = 0;
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    View3d *v = data;
    if (v->view) zs_view_orbit(v->view, (float)(dx - v->drag_x), (float)(dy - v->drag_y));
    v->drag_x = dx;
    v->drag_y = dy;
    queue_frame(v);
}

static gboolean on_scroll(GtkEventControllerScroll *c, double dx, double dy, gpointer data) {
    View3d *v = data;
    if (v->view) zs_view_zoom(v->view, powf(1.15f, (float)dy));
    queue_frame(v);
    return TRUE;
}

static void on_release(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    if (n != 1 || !v->view || fabs(x - v->press_x) > 4 || fabs(y - v->press_y) > 4) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    size_t path = zs_view_pick(v->view, (float)(x * scale), (float)(y * scale));
    zg_model_select(v->model, path == (size_t)-1 ? -1 : (gint64)path);
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_view_highlight(v->view, path < 0 ? (size_t)-1 : (size_t)path);
    queue_frame(v);
}

static void on_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    v->press_x = x;
    v->press_y = y;
    if (n != 2 || !v->view) return;
    zs_view_reset(v->view);
    queue_frame(v);
}

static void view_free(gpointer data) {
    View3d *v = data;
    g_signal_handlers_disconnect_by_data(v->model, v);
    if (v->idle) g_source_remove(v->idle);
    if (v->view) zs_view_free(v->view);
    zg_native_surface_free(v->native);
    g_free(v->error);
    g_object_unref(v->model);
    g_free(v);
}

GtkWidget *zg_view3d_new(ZgModel *model) {
    View3d *v = g_new0(View3d, 1);
    v->model = g_object_ref(model);
    v->area = gtk_drawing_area_new();
    gtk_widget_set_hexpand(v->area, TRUE);
    gtk_widget_set_vexpand(v->area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(v->area), draw_message, v, NULL);
    g_signal_connect(v->area, "map", G_CALLBACK(on_map), v);
    g_signal_connect(v->area, "unmap", G_CALLBACK(on_unmap), v);
    g_signal_connect(v->area, "resize", G_CALLBACK(on_resize), v);

    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), v);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), v);
    gtk_widget_add_controller(v->area, GTK_EVENT_CONTROLLER(drag));
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), v);
    gtk_widget_add_controller(v->area, scroll);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_click), v);
    g_signal_connect(click, "released", G_CALLBACK(on_release), v);
    gtk_widget_add_controller(v->area, GTK_EVENT_CONTROLLER(click));

    g_object_set_data_full(G_OBJECT(v->area), "zg-view3d", v, view_free);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), v);
    return v->area;
}
