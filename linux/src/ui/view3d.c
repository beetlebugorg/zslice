/* view3d.c: see view3d.h.
 *
 * The widget draws nothing: it is a transparent hole in the window, and the
 * core draws the 3D view with Vulkan into a native subsurface under it (see
 * native-surface.h). The widget only:
 *   - makes the subsurface and the core view the first time it is mapped,
 *     hides the subsurface when it is unmapped, and shows it again when it
 *     is mapped again. The view lives until the widget is destroyed: on
 *     NVIDIA, a teardown of a Vulkan device while GTK draws with GL
 *     crashes GTK on its next frame.
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
#include "preview.h"

#include <stdlib.h>

#include <math.h>

#include "native-surface.h"

typedef struct {
    ZgModel *model;
    GtkWidget *area;
    ZgNativeSurface *native;
    zs_view *view;
    char *error;
    size_t layer, layer_lo;
    int mode; /* enum zs_view_mode */
    gboolean zoomed;
    gboolean picked;
    gboolean timed;
    /* TRUE while the widget is unmapped: no frames, the subsurface is
     * hidden. */
    gboolean hidden;
    /* A Ctrl+drag that moves a part: the part, its place at the start,
     * and the bed point under the pointer at the start. */
    gint64 moving;
    /* A timeout that draws again after a skipped frame, or 0. */
    guint retry;
    gboolean menu_open;
    gboolean part_picked;
    gboolean zoomed_at;
    double move_x0, move_y0, bed_x0, bed_y0;
    /* The tick callback of the camera animation, or 0. */
    guint anim;
    gint64 anim_last;
    gboolean have_data;
    guint idle;
    double drag_x, drag_y;
    double press_x, press_y;
    double pointer_x, pointer_y;
    gboolean gaps_hook, gap_hook; /* the test hooks ran */
} View3d;

static void queue_frame(View3d *v);

static gboolean retry_frame(gpointer data) {
    View3d *v = data;
    v->retry = 0;
    queue_frame(v);
    return G_SOURCE_REMOVE;
}

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
        /* No free image now (the compositor holds them, for example while a
         * popup covers the window): draw again a moment later. */
        if (rc == ZS_BUSY) {
            if (!v->retry) v->retry = g_timeout_add(16, retry_frame, v);
        } else if (rc != ZS_OK) g_warning("zslice: the 3D view did not draw: %s", zg_status_text(rc));
    }
    return G_SOURCE_REMOVE;
}

static void queue_frame(View3d *v) {
    if (!v->idle && v->view && !v->hidden) v->idle = g_idle_add(draw_now, v);
}

/* The camera animation (smooth zoom and reset): one step on each frame of
 * the frame clock, until the core says that the camera is at rest. */
static gboolean on_animate(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    View3d *v = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    double dt = v->anim_last ? (now - v->anim_last) / 1e6 : 1.0 / 60;
    v->anim_last = now;
    gboolean moving = v->view && !v->hidden && zs_view_animate(v->view, MIN(dt, 0.1));
    queue_frame(v);
    if (moving) return G_SOURCE_CONTINUE;
    v->anim = 0;
    return G_SOURCE_REMOVE;
}

static void start_animation(View3d *v) {
    if (v->anim) return;
    v->anim_last = 0;
    v->anim = gtk_widget_add_tick_callback(v->area, on_animate, v, NULL);
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

/* The focus of the settings browser: for a first layer setting, only the
 * beads of the first layer. */
static void apply_focus(View3d *v) {
    if (!v->view) return;
    gboolean first = FALSE;
    guint32 mask = zg_model_focus(v->model, &first);
    double zmax = -1;
    zs_toolpaths tp;
    if (first && zs_app_toolpaths(zg_model_core(v->model), &tp) == ZS_OK && tp.layer_count > 0) zmax = tp.layer_z[0];
    zs_view_focus(v->view, mask, zmax);
}

static void on_focus_changed(ZgModel *model, gpointer data) {
    View3d *v = data;
    apply_focus(v);
    queue_frame(v);
}

static void on_copy_for_ai(GSimpleAction *a, GVariant *p, gpointer data);
static void on_new_profile(GSimpleAction *a, GVariant *p, gpointer data);

/* The gaps of the top layer, in red, while the gaps view is on. */
/* For screenshots: ZSLICE_GAP=n selects gap n of the layer in view. */
static void gap_hook_fire(gpointer data) {
    View3d *v = data;
    const char *gap = g_getenv("ZSLICE_GAP");
    if (gap) zg_model_select_gap(v->model, (gint64)v->layer, atoi(gap));
}

static void refresh_gaps(View3d *v) {
    if (!v->view) return;
    gboolean on = zg_model_gaps(v->model) && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE;
    zs_view_show_gaps(v->view, zg_model_core(v->model), on ? (int64_t)v->layer : -1);
}

static void on_gaps_changed(ZgModel *model, gpointer data) {
    View3d *v = data;
    refresh_gaps(v);
    queue_frame(v);
}

static void load_data(View3d *v) {
    if (!v->view) return;
    zs_view_set_mode(v->view, v->mode);
    int rc = zs_view_load(v->view, zg_model_core(v->model));
    if (rc != ZS_OK) {
        g_warning("zslice: the 3D view did not load the toolpaths: %s", zg_status_text(rc));
        return;
    }
    zs_view_set_layer_range(v->view, v->layer_lo, v->layer);
    gint64 sel = zg_model_selected(v->model);
    zs_view_highlight(v->view, sel < 0 ? (size_t)-1 : (size_t)sel);
    apply_focus(v);
    /* For tests: ZSLICE_GAPS=1 turns the gaps view on, and ZSLICE_GAP=N
     * selects gap N of the top layer after a slice. */
    if (g_getenv("ZSLICE_GAPS") && !v->gaps_hook) {
        v->gaps_hook = TRUE;
        zg_model_set_gaps(v->model, TRUE);
    }
    refresh_gaps(v);
    const char *gap = g_getenv("ZSLICE_GAP");
    /* 2 s later: the gap of the layer that the view shows then (the
     * preview sets the layer after the first result). */
    if (gap && zg_model_gaps(v->model) && !v->gap_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->gap_hook = TRUE;
        g_timeout_add_once(2000, gap_hook_fire, v);
    }
    /* For development and screenshots: ZSLICE_PART=1 selects that part of
     * the plate after the first load. */
    const char *part = g_getenv("ZSLICE_PART");
    if (part && !v->part_picked && zs_app_part_count(zg_model_core(v->model)) > (size_t)atoi(part)) {
        v->part_picked = TRUE;
        zg_model_select_part(v->model, atoi(part));
        /* As after a Ctrl+click: the keys go to the preview. */
        GtkWidget *preview = gtk_widget_get_ancestor(v->area, GTK_TYPE_OVERLAY);
        if (preview) gtk_widget_grab_focus(preview);
        /* ZSLICE_PART_SCOPE=1: the editors change that part, and
         * ZSLICE_PART_SET=name=value sets one value of it. */
        const char *scope = g_getenv("ZSLICE_PART_SCOPE");
        if (scope) {
            zg_model_set_part_scope(v->model, atoi(scope));
            const char *set = g_getenv("ZSLICE_PART_SET");
            char **kv = set ? g_strsplit(set, "=", 2) : NULL;
            if (kv && kv[0] && kv[1]) zg_model_set_for(v->model, kv[0], kv[1], FALSE, NULL);
            g_strfreev(kv);
        }
    }
    /* For development and screenshots: ZSLICE_ZOOM=0.3 starts nearer. */
    const char *zoom = g_getenv("ZSLICE_ZOOM");
    if (zoom && !v->zoomed && zs_app_layer_count(zg_model_core(v->model)) > 0) {
        zs_view_zoom(v->view, (float)g_ascii_strtod(zoom, NULL));
        v->zoomed = TRUE;
    }
    /* For development and screenshots: ZSLICE_ZOOM_AT=x,y,n zooms n wheel
     * steps toward that pixel (logical points) after the first load. */
    const char *zat = g_getenv("ZSLICE_ZOOM_AT");
    if (zat && !v->zoomed_at && zs_app_layer_count(zg_model_core(v->model)) > 0) {
        char **f = g_strsplit(zat, ",", 3);
        if (f[0] && f[1] && f[2]) {
            int scale = gtk_widget_get_scale_factor(v->area);
            for (int i = 0; i < atoi(f[2]); i++)
                zs_view_zoom_at(v->view, 0.8f, (float)(g_ascii_strtod(f[0], NULL) * scale), (float)(g_ascii_strtod(f[1], NULL) * scale));
        }
        g_strfreev(f);
        v->zoomed_at = TRUE;
        start_animation(v);
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
            zs_view_set_layer_range(v->view, v->layer_lo, v->layer);
            size_t path = zs_view_pick(v->view, (float)(g_ascii_strtod(xy[0], NULL) * scale), (float)(g_ascii_strtod(xy[1], NULL) * scale));
            v->picked = TRUE;
            if (path != (size_t)-1) zg_model_select(v->model, (gint64)path);
            /* For tests: ZSLICE_COPY_FOR_AI=1 runs "Copy for AI" on it. */
            if (path != (size_t)-1 && g_getenv("ZSLICE_COPY_FOR_AI")) on_copy_for_ai(NULL, NULL, v);
            /* ZSLICE_PROFILE=up (or down): "New profile from here up". */
            const char *prof = g_getenv("ZSLICE_PROFILE");
            if (path != (size_t)-1 && prof) {
                GVariant *dir = g_variant_ref_sink(g_variant_new_int32(strcmp(prof, "down") == 0 ? -1 : 1));
                on_new_profile(NULL, dir, v);
                g_variant_unref(dir);
                /* ZSLICE_PROFILE_SET=name=value: one change in it. */
                const char *set = g_getenv("ZSLICE_PROFILE_SET");
                char **kv = set ? g_strsplit(set, "=", 2) : NULL;
                if (kv && kv[0] && kv[1]) zg_model_set_for(v->model, kv[0], kv[1], TRUE, NULL);
                g_strfreev(kv);
            }
            /* As after a click: the keys go to the preview. */
            GtkWidget *preview = gtk_widget_get_ancestor(v->area, GTK_TYPE_OVERLAY);
            if (preview) gtk_widget_grab_focus(preview);
        }
        g_strfreev(xy);
    }
    queue_frame(v);
}

gboolean zg_view3d_legend(GtkWidget *view, double *min, double *max) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v->view && zs_view_legend(v->view, min, max);
}

void zg_view3d_set_color_mode(GtkWidget *view, int mode) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    v->mode = mode;
    load_data(v);
}

static void on_map(GtkWidget *w, gpointer data) {
    View3d *v = data;
    v->hidden = FALSE;
    if (v->view) {
        /* Mapped again: the next frame attaches a buffer, and that shows
         * the subsurface. The data can be new since the unmap. */
        load_data(v);
        sync_geometry(v);
        return;
    }
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
    v->hidden = TRUE;
    /* No frame clock ticks while unmapped: stop the animation. */
    if (v->anim) gtk_widget_remove_tick_callback(v->area, v->anim);
    v->anim = 0;
    if (v->idle) {
        g_source_remove(v->idle);
        v->idle = 0;
    }
    if (v->native) zg_native_surface_hide(v->native);
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

void zg_view3d_set_layer_range(GtkWidget *view, size_t lo, size_t hi) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    v->layer = hi;
    v->layer_lo = lo;
    if (v->view) zs_view_set_layer_range(v->view, lo, hi);
    refresh_gaps(v);
    queue_frame(v);
}

void zg_view3d_set_layer(GtkWidget *view, size_t layer) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    v->layer = layer;
    v->layer_lo = 0;
    if (v->view) zs_view_set_layer(v->view, layer);
    refresh_gaps(v);
    queue_frame(v);
}

/* The mouse, as in Cura, Tinkercad, and Fusion: a left or a right drag
 * orbits (turn and tilt, the bed stays level), a middle drag pans, and the
 * scroll wheel zooms toward the pointer. */
enum { DRAG_ORBIT, DRAG_PAN, DRAG_ROTATE };

/* The part under a pixel: the part of the path there, or the part whose
 * footprint holds the bed point there. */
static gint64 part_at(View3d *v, double x, double y, double *bx, double *by) {
    int scale = gtk_widget_get_scale_factor(v->area);
    zs_app *core = zg_model_core(v->model);
    double px = 0, py = 0;
    gboolean on_bed = zs_view_bed_point(v->view, (float)(x * scale), (float)(y * scale), &px, &py);
    if (bx) *bx = px;
    if (by) *by = py;
    size_t path = zs_view_pick(v->view, (float)(x * scale), (float)(y * scale));
    if (path != (size_t)-1) {
        ptrdiff_t part = zs_app_part_of_path(core, path);
        if (part >= 0) return part;
    }
    return on_bed ? zs_app_part_at(core, px, py) : -1;
}

/* The frame of the selected part on the bed. */
static void show_part_box(View3d *v) {
    if (!v->view) return;
    gint64 i = zg_model_selected_part(v->model);
    zs_part p;
    if (i >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) == ZS_OK) {
        zs_view_part_box(v->view, p.x - p.size_x / 2, p.y - p.size_y / 2, p.x + p.size_x / 2, p.y + p.size_y / 2);
    } else {
        zs_view_part_box(v->view, 1, 1, 0, 0);
    }
    queue_frame(v);
}

static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    show_part_box(data);
}

static void on_plate_changed(ZgModel *model, gpointer data) {
    show_part_box(data);
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    View3d *v = data;
    v->drag_x = 0;
    v->drag_y = 0;
    v->moving = -1;
    /* Ctrl and the left button on a part: move the part. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    if (v->view && mode == DRAG_ORBIT && (mods & GDK_CONTROL_MASK)) {
        double bx, by;
        gint64 part = part_at(v, x, y, &bx, &by);
        zs_part p;
        if (part >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)part, &p) == ZS_OK) {
            zg_model_select_part(v->model, part);
            v->moving = part;
            v->move_x0 = p.x;
            v->move_y0 = p.y;
            v->bed_x0 = bx;
            v->bed_y0 = by;
            gtk_widget_set_cursor_from_name(v->area, "move");
            return;
        }
    }
    gtk_widget_set_cursor_from_name(v->area, "grabbing");
}

static void menu_at(View3d *v, double x, double y);

static void on_drag_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    View3d *v = data;
    v->moving = -1;
    gtk_widget_set_cursor(v->area, NULL);
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    if (mode == DRAG_ROTATE && fabs(dx) < 4 && fabs(dy) < 4) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        menu_at(v, sx, sy);
    }
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    View3d *v = data;
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    int scale = gtk_widget_get_scale_factor(v->area);
    float ddx = (float)(dx - v->drag_x), ddy = (float)(dy - v->drag_y);
    if (v->view && v->moving >= 0) {
        /* The part follows the bed point under the pointer. */
        double sx, sy, bx, by;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        if (zs_view_bed_point(v->view, (float)((sx + dx) * scale), (float)((sy + dy) * scale), &bx, &by)) {
            zg_model_part_move(v->model, (size_t)v->moving, v->move_x0 + bx - v->bed_x0, v->move_y0 + by - v->bed_y0);
        }
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (v->view) {
        switch (mode) {
        case DRAG_PAN: zs_view_pan(v->view, ddx * scale, ddy * scale); break;
        default: zs_view_orbit(v->view, ddx, ddy); break;
        }
    }
    v->drag_x = dx;
    v->drag_y = dy;
    queue_frame(v);
}

static void on_motion(GtkEventControllerMotion *c, double x, double y, gpointer data) {
    View3d *v = data;
    v->pointer_x = x;
    v->pointer_y = y;
}

static gboolean on_scroll(GtkEventControllerScroll *c, double dx, double dy, gpointer data) {
    View3d *v = data;
    int scale = gtk_widget_get_scale_factor(v->area);
    /* Ctrl and the wheel: turn the selected part by 15 degrees a step. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c));
    gint64 part = zg_model_selected_part(v->model);
    if ((mods & GDK_CONTROL_MASK) && part >= 0) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(v->model), (size_t)part, &p) == ZS_OK) {
            /* GTK can turn a vertical wheel with Shift into dx. */
            double step = dy != 0 ? dy : dx;
            zg_model_part_rotate(v->model, (size_t)part, p.rotation + (step > 0 ? -15 : 15));
        }
        return TRUE;
    }
    if (v->view) zs_view_zoom_at(v->view, powf(1.15f, (float)dy), (float)(v->pointer_x * scale), (float)(v->pointer_y * scale));
    start_animation(v);
    return TRUE;
}

static void on_release(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    if (n != 1 || !v->view || fabs(x - v->press_x) > 4 || fabs(y - v->press_y) > 4) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    /* Ctrl+click: select a part (to move, turn, or remove it). A click: a
     * line. Shift+click: add a line to the selection, or take it out. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    if (mods & GDK_CONTROL_MASK) {
        zg_model_select_part(v->model, part_at(v, x, y, NULL, NULL));
        return;
    }
    /* The gaps view: a click on a gap selects it. */
    if (zg_model_gaps(v->model)) {
        int64_t gap = zs_view_gap_at(v->view, zg_model_core(v->model), (float)(x * scale), (float)(y * scale));
        if (gap >= 0) {
            zg_model_select(v->model, -1);
            zg_model_select_gap(v->model, (gint64)v->layer, gap);
            return;
        }
        zg_model_select_gap(v->model, -1, -1);
    }
    /* The line, and the segment of it under the pointer (the keys h and l
     * go on from there). */
    size_t seg = 0;
    size_t path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
    if (mods & GDK_SHIFT_MASK) {
        if (path != (size_t)-1) zg_model_toggle_more(v->model, (gint64)path);
        return;
    }
    if (path == (size_t)-1) zg_model_select(v->model, -1);
    else zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
}

/* ---- the context menu ----
 *
 * A right click on a line selects it (and its segment), and the menu acts
 * at the middle of that segment, on its layer: support of a kind there, no
 * support there, or no marks there. */

/* The place of the menu: x, y, z in mm, from the selected segment. */
static gboolean mark_place(View3d *v, double *x, double *y, double *z) {
    gint64 path = zg_model_selected(v->model);
    zs_toolpaths tp;
    if (path < 0 || zs_app_toolpaths(zg_model_core(v->model), &tp) != ZS_OK || (size_t)path >= tp.path_count) return FALSE;
    uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
    if (b <= a) return FALSE;
    gint64 seg = zg_model_segment(v->model);
    uint32_t i = seg >= 0 && a + (uint32_t)seg + 1 < b ? a + (uint32_t)seg : a + (b - a) / 2 - ((b - a) > 1 ? 1 : 0);
    uint32_t j = i + 1 < b ? i + 1 : i;
    *x = (tp.points[2 * i] + tp.points[2 * j]) / 2;
    *y = (tp.points[2 * i + 1] + tp.points[2 * j + 1]) / 2;
    size_t layer = 0;
    while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
    *z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
    return TRUE;
}

static void on_add_support(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    double x, y, z;
    if (mark_place(v, &x, &y, &z)) zg_model_mark_add(v->model, x, y, z, 3, g_variant_get_int32(p));
}

static void on_remove_marks(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    double x, y, z;
    if (mark_place(v, &x, &y, &z)) zg_model_mark_remove_near(v->model, x, y, z, 3);
}

/* The part of the selected line, or -1. */
static gint64 menu_part(View3d *v) {
    gint64 path = zg_model_selected(v->model);
    if (path < 0) return -1;
    ptrdiff_t part = zs_app_part_of_path(zg_model_core(v->model), (size_t)path);
    return part < 0 ? -1 : part;
}

static void on_put_down(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    double x, y, z;
    gint64 part = menu_part(v);
    if (part >= 0 && mark_place(v, &x, &y, &z)) zg_model_part_put_down_at(v->model, (size_t)part, x, y, z);
}

static void on_place(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    gint64 part = menu_part(v);
    gint32 code = g_variant_get_int32(p);
    /* 0 smart, 1 less support, 10 + axis: strong along that axis. */
    if (part < 0) return;
    if (code >= 10) zg_model_part_place(v->model, (size_t)part, ZS_PLACE_STRENGTH, code - 10);
    else zg_model_part_place(v->model, (size_t)part, code, 0);
}

/* "Copy for AI": the G-code of the slice to a file in the cache folder,
 * and a report of the selected line (what it is, why, its settings, and
 * its lines in that file) to the clipboard, to paste into an AI chat. */
static void on_copy_for_ai(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    gint64 path = zg_model_selected(v->model);
    zs_app *core = zg_model_core(v->model);
    const uint8_t *gcode = NULL;
    size_t glen = 0;
    if (path < 0 || zs_app_gcode(core, &gcode, &glen) != ZS_OK) return;
    char *dir = g_build_filename(g_get_user_cache_dir(), "zslice", NULL);
    g_mkdir_with_parents(dir, 0700);
    char *file = g_build_filename(dir, "last-slice.gcode", NULL);
    GError *error = NULL;
    if (!g_file_set_contents(file, (const char *)gcode, (gssize)glen, &error)) {
        g_warning("zslice: the G-code was not saved for the report: %s", error->message);
        g_clear_error(&error);
    }
    const char *report = NULL;
    size_t rlen = 0;
    if (zs_app_line_report(core, (size_t)path, file, &report, &rlen) == ZS_OK) {
        char *text = g_strndup(report, rlen);
        gdk_clipboard_set_text(gdk_display_get_clipboard(gtk_widget_get_display(v->area)), text);
        /* The test hook (no input event, so Wayland may refuse the
         * clipboard): the text to the log too. */
        if (g_getenv("ZSLICE_COPY_FOR_AI")) g_printerr("%s\n", text);
        g_free(text);
    }
    g_free(file);
    g_free(dir);
}

/* "New profile from here up" (1) or "down" (-1): a layer profile from
 * the layer of the selected line, opened in the settings browser. */
static void on_new_profile(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    int dir = g_variant_get_int32(p);
    gint64 path = zg_model_selected(v->model);
    zs_inspect info;
    if (path < 0 || zs_app_inspect(zg_model_core(v->model), (size_t)path, &info) != ZS_OK) return;
    double z_min = dir > 0 ? info.z : -1e6, z_max = dir > 0 ? 1e6 : info.z;
    char *name = g_strdup_printf(dir > 0 ? "Layers %zu and up" : "Layers 1 to %zu", info.layer + 1);
    zg_model_profile_set(v->model, z_min, z_max, name);
    g_free(name);
    zg_model_open_profile(v->model, z_min, z_max);
}

static void on_clear_marks(GSimpleAction *a, GVariant *p, gpointer data) {
    zg_model_marks_clear(((View3d *)data)->model);
}

static void on_reset_view(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_view_reset_smooth(v->view);
    start_animation(v);
}

static void show_menu(View3d *v, double x, double y);

static gboolean on_menu_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    if (key != GDK_KEY_Escape) return FALSE;
    gtk_popover_popdown(GTK_POPOVER(data));
    return TRUE;
}

static gboolean unparent_later(gpointer data) {
    gtk_widget_unparent(data);
    g_object_unref(data);
    return G_SOURCE_REMOVE;
}

static void on_menu_closed(GtkPopover *pop, gpointer data) {
    View3d *v = data;
    v->menu_open = FALSE;
    /* The keys go to the preview again (the arrows, h j k l). */
    GtkWidget *preview = gtk_widget_get_ancestor(v->area, GTK_TYPE_OVERLAY);
    if (preview) gtk_widget_grab_focus(preview);
    g_idle_add(unparent_later, g_object_ref(pop));
}

gboolean zg_view3d_menu_open(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && v->menu_open;
}

/* A right click (a right drag of less than 4 pixels) at x, y: select the
 * line there, and open the menu. */
static void menu_at(View3d *v, double x, double y) {
    if (!v->view) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    size_t seg = 0;
    size_t path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
    if (path != (size_t)-1) zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
    show_menu(v, x, y);
}

/* The menu from the keyboard (the Menu key, or Shift+F10): for the line
 * that is selected now, in the middle of the view. */
void zg_view3d_context_menu(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    show_menu(v, gtk_widget_get_width(v->area) / 2.0, gtk_widget_get_height(v->area) / 2.0);
}

static void show_menu(View3d *v, double x, double y) {
    gboolean on_line = zg_model_selected(v->model) >= 0;
    GMenu *menu = g_menu_new();
    if (on_line) {
        GMenu *kinds = g_menu_new();
        g_menu_append(kinds, "Grid", "view3d.add-support(0)");
        g_menu_append(kinds, "Tree", "view3d.add-support(1)");
        g_menu_append(kinds, "Bridge (a pad)", "view3d.add-support(2)");
        GMenu *here = g_menu_new();
        g_menu_append_submenu(here, "Add support here", G_MENU_MODEL(kinds));
        g_menu_append(here, "Block support here", "view3d.add-support(3)");
        g_menu_append(here, "Remove the support marks here", "view3d.remove-marks");
        g_menu_append(here, "Copy for AI", "view3d.copy-for-ai");
        GMenuItem *cut = g_menu_item_new("Preview to this layer", "preview.cut-to-layer");
        g_menu_item_set_attribute(cut, "accel", "s", "c");
        g_menu_prepend_item(here, cut);
        g_object_unref(cut);
        g_menu_append_section(menu, NULL, G_MENU_MODEL(here));
        GMenu *prof = g_menu_new();
        g_menu_append(prof, "New profile from here up", "view3d.new-profile(1)");
        g_menu_append(prof, "New profile from here down", "view3d.new-profile(-1)");
        g_menu_append_section(menu, NULL, G_MENU_MODEL(prof));
        g_object_unref(prof);
        g_object_unref(kinds);
        g_object_unref(here);
        /* The part of the line: its placement. */
        GMenu *part = g_menu_new();
        g_menu_append(part, "Put this side on the bed", "view3d.put-down");
        GMenu *modes = g_menu_new();
        g_menu_append(modes, "Smart placement", "view3d.place(0)");
        g_menu_append(modes, "Less support", "view3d.place(1)");
        g_menu_append(modes, "Strong along X of the part", "view3d.place(10)");
        g_menu_append(modes, "Strong along Y of the part", "view3d.place(11)");
        g_menu_append(modes, "Strong along Z of the part", "view3d.place(12)");
        g_menu_append_submenu(part, "Placement", G_MENU_MODEL(modes));
        g_menu_append_section(menu, NULL, G_MENU_MODEL(part));
        g_object_unref(modes);
        g_object_unref(part);
    }
    GMenu *plate = g_menu_new();
    g_menu_append(plate, "Smart placement", "win.smart-place");
    g_menu_append(plate, "Arrange the plate", "win.arrange");
    g_menu_append(plate, "Add models\u2026", "app.open");
    g_menu_append(plate, "Clear the plate", "win.clear-plate");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(plate));
    g_object_unref(plate);
    GMenu *general = g_menu_new();
    if (zs_app_mark_count(zg_model_core(v->model)) > 0) g_menu_append(general, "Clear all support marks", "view3d.clear-marks");
    GtkWidget *preview = v->area;
    while (preview && !g_object_get_data(G_OBJECT(preview), "zg-preview")) preview = gtk_widget_get_parent(preview);
    if (preview && zg_preview_is_cut(preview)) {
        GMenuItem *all = g_menu_item_new("Show all layers", "preview.all-layers");
        g_menu_item_set_attribute(all, "accel", "s", "<Shift>c");
        g_menu_append_item(general, all);
        g_object_unref(all);
    }
    g_menu_append(general, "Reset the view", "view3d.reset-view");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(general));
    g_object_unref(general);
    GtkWidget *pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_widget_set_parent(pop, v->area);
    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    GdkRectangle at = {(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &at);
    /* Esc closes the menu (also from a submenu). */
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_menu_key), pop);
    gtk_widget_add_controller(pop, keys);
    /* Removed after the close, not in its handler. */
    g_signal_connect(pop, "closed", G_CALLBACK(on_menu_closed), v);
    v->menu_open = TRUE;
    gtk_popover_popup(GTK_POPOVER(pop));
}

static void on_selection(ZgModel *model, gint64 path, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_view_highlight(v->view, path < 0 ? (size_t)-1 : (size_t)path);
    zs_view_isolate(v->view, zg_model_isolate(model));
    if (path >= 0) zs_view_highlight_segment(v->view, (size_t)path, (ptrdiff_t)zg_model_segment(model));
    /* The other lines of a multiple selection. */
    guint n = 0;
    const gint64 *more = zg_model_more(model, &n);
    size_t *list = g_new(size_t, n + 1);
    size_t k = 0;
    for (guint i = 0; i < n; i++) if (more[i] >= 0) list[k++] = (size_t)more[i];
    zs_view_highlight_more(v->view, list, k);
    g_free(list);
    queue_frame(v);
}

static void on_segment(ZgModel *model, gint64 seg, gpointer data) {
    View3d *v = data;
    gint64 path = zg_model_selected(model);
    if (!v->view || path < 0) return;
    zs_view_highlight_segment(v->view, (size_t)path, (ptrdiff_t)seg);
    queue_frame(v);
}

static void on_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    v->press_x = x;
    v->press_y = y;
    if (n != 2 || !v->view) return;
    zs_view_reset_smooth(v->view);
    start_animation(v);
}

static void view_free(gpointer data) {
    View3d *v = data;
    g_signal_handlers_disconnect_by_data(v->model, v);
    if (v->idle) g_source_remove(v->idle);
    if (v->retry) g_source_remove(v->retry);
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

    const struct { guint button; int mode; } drags[] = {
        {GDK_BUTTON_PRIMARY, DRAG_ORBIT},
        {GDK_BUTTON_MIDDLE, DRAG_PAN},
        {GDK_BUTTON_SECONDARY, DRAG_ROTATE},
    };
    for (size_t i = 0; i < G_N_ELEMENTS(drags); i++) {
        GtkGesture *drag = gtk_gesture_drag_new();
        gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), drags[i].button);
        g_object_set_data(G_OBJECT(drag), "zg-drag", GINT_TO_POINTER(drags[i].mode));
        g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), v);
        g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), v);
        g_signal_connect(drag, "drag-end", G_CALLBACK(on_drag_end), v);
        gtk_widget_add_controller(v->area, GTK_EVENT_CONTROLLER(drag));
    }
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), v);
    gtk_widget_add_controller(v->area, motion);
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), v);
    gtk_widget_add_controller(v->area, scroll);
    /* The context menu: a right drag that ends where it began (see
     * on_drag_end). One gesture for the right button, so the drag and the
     * click do not compete for the press. */
    static const GActionEntry menu_actions[] = {
        {.name = "add-support", .activate = on_add_support, .parameter_type = "i"},
        {.name = "remove-marks", .activate = on_remove_marks},
        {.name = "clear-marks", .activate = on_clear_marks},
        {.name = "put-down", .activate = on_put_down},
        {.name = "copy-for-ai", .activate = on_copy_for_ai},
        {.name = "new-profile", .activate = on_new_profile, .parameter_type = "i"},
        {.name = "place", .activate = on_place, .parameter_type = "i"},
        {.name = "reset-view", .activate = on_reset_view},
    };
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), menu_actions, G_N_ELEMENTS(menu_actions), v);
    gtk_widget_insert_action_group(v->area, "view3d", G_ACTION_GROUP(group));
    g_object_unref(group);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_click), v);
    g_signal_connect(click, "released", G_CALLBACK(on_release), v);
    gtk_widget_add_controller(v->area, GTK_EVENT_CONTROLLER(click));

    g_object_set_data_full(G_OBJECT(v->area), "zg-view3d", v, view_free);
    g_signal_connect(model, "selection-changed", G_CALLBACK(on_selection), v);
    g_signal_connect(model, "gaps-changed", G_CALLBACK(on_gaps_changed), v);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), v);
    g_signal_connect(model, "segment-changed", G_CALLBACK(on_segment), v);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plate_changed), v);
    g_signal_connect(model, "focus-changed", G_CALLBACK(on_focus_changed), v);
    return v->area;
}
