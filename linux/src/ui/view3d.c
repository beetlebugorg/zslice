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
 * The rings of the Turn tool (as web/app/turn.js): with the Turn tool and
 * a selected part, three rings go around the part: red turns it about X,
 * green about Y, and blue about Z (on the bed). The core view draws them,
 * finds the ring under the pointer, and gives the angle of a drag
 * (zs_view_set_rings, zs_view_ring_*). A drag turns the part in steps of
 * 15 degrees (Shift: 5); each step goes to the core at once, and the part
 * slices once, at the end of the drag. The widget draws over the
 * subsurface with cairo: the label of the angle.
 *
 * The Support tool (support-tool.h) gets the clicks, the drags, and the
 * keys of the view while it is on.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "view3d.h"
#include "preview.h"

#include <stdlib.h>
#include <string.h>

#include <math.h>

#include "bed-model.h"
#include "native-surface.h"
#include "range-card.h"
#include "support-tool.h"
#include "widgets.h"

typedef struct {
    ZgModel *model;
    GtkWidget *area;
    ZgNativeSurface *native;
    zs_view *view;
    /* A camera of a session, set before the view had its data: the next
     * load applies it. */
    float pending_camera[8];
    gboolean has_pending_camera;
    char *error;
    size_t layer, layer_lo;
    int mode; /* enum zs_view_mode */
    gboolean zoomed;
    /* The last scroll came from a touchpad: a right drag (two fingers
     * clicked down) pans. A mouse wheel, or no scroll yet: it orbits. */
    gboolean touchpad;
    gboolean picked;
    gboolean timed;
    /* TRUE while the widget is unmapped: no frames, the subsurface is
     * hidden. */
    gboolean hidden;
    /* A Ctrl+drag that moves a part: the part, its place at the start,
     * and the bed point under the pointer at the start. */
    gint64 moving;
    /* A drag of a part of a selection of several parts moves them all:
     * their indexes and their places at the start (x, y pairs). */
    GArray *group, *group_xy;
    /* A left drag of the Select tool that started on a line: the layers
     * from range_layer to range_cur light up (range_lit after the first
     * move), and range_pt is the point of the press (mm), the anchor of
     * the layer under the pointer (range_layer_at). */
    gboolean range_on, range_lit;
    size_t range_layer, range_cur;
    double range_pt[2];
    /* The line of the press of that drag. */
    size_t range_path;
    /* The lit range of layers (a drag, or Shift+K and Shift+J): the line
     * that it starts from (-1: all the lines of the layers), the layer of
     * that line, and the layers. A new load lights it again (relight).
     * light_on while it shows. */
    gboolean light_on;
    gint64 light_path;
    ptrdiff_t light_layer;
    size_t light_lo, light_hi;
    /* Shift+K and Shift+J: the first layer of the range, the layer that
     * moves, and the selected line at the start. key_on while that range
     * shows. */
    gboolean key_on;
    size_t key_a, key_b;
    gint64 key_path;
    /* TRUE while the run of a Shift+click shows. */
    gboolean run_lit;
    /* A timeout that draws again after a skipped frame, or 0. */
    guint retry;
    gboolean menu_open;
    gboolean part_picked;
    gboolean zoomed_at;
    double move_x0, move_y0, bed_x0, bed_y0;
    /* The end of the measure tape that a drag moves, or -1. */
    int tape_end;
    /* The tick callback of the camera animation, or 0. */
    guint anim;
    gint64 anim_last;
    gboolean have_data;
    guint idle;
    double drag_x, drag_y;
    double press_x, press_y;
    /* The place of the last right click (points), for a drop. */
    double menu_x, menu_y;
    double pointer_x, pointer_y;
    gboolean gaps_hook, gap_hook; /* the test hooks ran */
    gboolean dbl_hook, ring_hook, grab_hook, menu_hook, select_hook;
    /* ZSLICE_BENCH: the step (0 off, 1 wait for the first frame, 2 orbit,
     * 3 wait for the slice of an edit, 4 done), the frames of the orbit,
     * their draw times (ms), the time of the last tick, and the time of
     * the edit. */
    int bench;
    int bench_frames, bench_busy;
    double bench_gap_max;
    gint64 bench_tick;
    double bench_draw[240];
    gint64 bench_last, bench_edit;
    /* The calls after each frame (zg_view3d_on_frame). */
    GArray *hooks;
    /* The rings of the Turn tool are on (the core view draws them). */
    gboolean rings_on;
    /* A drag of a ring: its axis (-1: none), the angle of the press, the
     * sense of the ring on the screen, the turn that the drag wants, the
     * turn sent to the core, and the pointer (for the label). */
    int turn_axis;
    double turn_want, turn_sent;
    double turn_px, turn_py;
    /* The Support tool, and the cursor that it set last. */
    ZgSupport *support;
    const char *cursor;
    /* The fall of a part, or the hand that holds it: a tick on each frame
     * runs the rigid body (zg_model_fall_step). */
    guint fall_tick;
    gint64 fall_part, fall_last;
    /* The hand (the Grab tool) is sticky: a click picks a part up, and
     * the hand keeps it with no button held, until the next click or Esc.
     * Its height over the bed (mm), its last pointer, the pointer of an
     * Alt move, and the turn of the Alt moves (degrees: the sum, and the
     * part sent). hand_click: the press of that click (no orbit). */
    gboolean hand, hand_click, turning;
    double hand_h, hand_px, hand_py, turn_x, turn_y;
    double yaw, tilt, yaw_sent, tilt_sent;
} View3d;

typedef struct {
    GtkWidget *owner;
    void (*fn)(gpointer);
    gpointer data;
} FrameHook;


static void queue_frame(View3d *v);
static void bench_start(View3d *v);
static void compute_rings(View3d *v);
static void fall_finish(View3d *v);
static void set_cursor(View3d *v, const char *name);

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
        gint64 t0 = g_get_monotonic_time();
        int rc = zs_view_draw(v->view);
        if (v->bench == 2 && v->bench_frames < (int)G_N_ELEMENTS(v->bench_draw))
            v->bench_draw[v->bench_frames] = (g_get_monotonic_time() - t0) / 1000.0;
        /* ZSLICE_BENCH_WAIT=ms: the orbit starts that long after the start
         * (for example after ZSLICE_PLATES and Home). */
        const char *wait = g_getenv("ZSLICE_BENCH_WAIT");
        gboolean waited = !wait || g_get_monotonic_time() - zg_start_us > g_ascii_strtoll(wait, NULL, 10) * 1000;
        if (v->bench == 1 && rc == ZS_OK && waited && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) bench_start(v);
        /* No free image now (the compositor holds them, for example while a
         * popup covers the window): draw again a moment later. */
        if (rc == ZS_BUSY) {
            if (v->bench == 2) v->bench_busy++;
            if (!v->retry) v->retry = g_timeout_add(16, retry_frame, v);
        } else if (rc != ZS_OK) g_warning("zslice: the 3D view did not draw: %s", zg_status_text(rc));
        /* The rings and the cards follow the camera. */
        gboolean had = v->rings_on;
        compute_rings(v);
        if (had || v->rings_on) gtk_widget_queue_draw(v->area);
        for (guint i = 0; v->hooks && i < v->hooks->len; i++) {
            FrameHook *h = &g_array_index(v->hooks, FrameHook, i);
            h->fn(h->data);
        }
    }
    return G_SOURCE_REMOVE;
}

static void queue_frame(View3d *v) {
    if (!v->idle && v->view && !v->hidden) v->idle = g_idle_add(draw_now, v);
}

/* ---- ZSLICE_BENCH=1: the times of the app ----
 *
 * The log gives the time from the start of the process to the first frame
 * of the slice, the draw time of 240 frames of an orbit (2 degrees each
 * frame) and their rate, and the time from an edit (the wall count) to the
 * first frame of its slice. */

gint64 zg_start_us;

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static gboolean on_bench_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    View3d *v = data;
    if (!v->view || v->bench != 2) return G_SOURCE_REMOVE;
    if (v->bench_frames >= (int)G_N_ELEMENTS(v->bench_draw)) {
        gint64 now = g_get_monotonic_time();
        int n = v->bench_frames;
        double sorted[G_N_ELEMENTS(v->bench_draw)], sum = 0;
        memcpy(sorted, v->bench_draw, sizeof sorted);
        qsort(sorted, (size_t)n, sizeof(double), cmp_double);
        for (int i = 0; i < n; i++) sum += sorted[i];
        g_message("bench: orbit of %d frames: %.1f frames a second (the longest frame %.1f ms, %d busy), draw %.2f ms on average, %.2f ms at "
                  "the 95th percentile, %.2f ms at most",
                  n, n / ((now - v->bench_last) / 1e6), v->bench_gap_max, v->bench_busy, sum / n, sorted[n * 95 / 100], sorted[n - 1]);
        v->bench = 3;
        v->bench_edit = g_get_monotonic_time();
        zg_model_set(v->model, "project.wall_count", "3", NULL);
        return G_SOURCE_REMOVE;
    }
    gint64 tick = g_get_monotonic_time();
    if (v->bench_frames == 0) {
        v->bench_last = tick;
        v->bench_busy = 0;
        v->bench_gap_max = 0;
    } else {
        double gap = (tick - v->bench_tick) / 1000.0;
        if (gap > 40) g_message("bench: frame %d took %.0f ms, %.0f ms after the start", v->bench_frames, gap, (tick - zg_start_us) / 1000.0);
        v->bench_gap_max = MAX(v->bench_gap_max, gap);
    }
    v->bench_tick = tick;
    zs_view_orbit(v->view, 2, 0);
    v->bench_frames++;
    queue_frame(v);
    return G_SOURCE_CONTINUE;
}

static void bench_start(View3d *v) {
    g_message("bench: the first frame of the slice, %.0f ms after the start", (g_get_monotonic_time() - zg_start_us) / 1000.0);
    v->bench = 2;
    v->bench_frames = 0;
    gtk_widget_add_tick_callback(v->area, on_bench_tick, v, NULL);
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
    /* The Support tool: a focus on all features but the support, so the
     * support lines are faint and the outlines of the areas show. */
    if (!mask && zg_support_see_through(v->support)) {
        mask = ((1u << ZS_FEATURE_COUNT) - 1) & ~((1u << ZS_FEATURE_SUPPORT) | (1u << ZS_FEATURE_SUPPORT_INTERFACE));
        first = FALSE;
    }
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
static void on_add_drop(GSimpleAction *a, GVariant *p, gpointer data);
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

static gboolean look_at_side(View3d *v, double x, double y);
static void ring_drag_hook(gpointer data);
static void grab_hook(gpointer data);
static void menu_hook(gpointer data);
static void select_hook(gpointer data);
static void relight(View3d *v);

/* For tests: ZSLICE_DOUBLE_CLICK=x,y is a double click at that pixel. */
static void dbl_hook_fire(gpointer data) {
    View3d *v = data;
    char **xy = g_strsplit(g_getenv("ZSLICE_DOUBLE_CLICK"), ",", 2);
    if (xy[0] && xy[1] && v->view && !look_at_side(v, g_ascii_strtod(xy[0], NULL), g_ascii_strtod(xy[1], NULL))) {
        zs_view_reset_smooth(v->view);
        start_animation(v);
    }
    g_strfreev(xy);
}

static void load_data(View3d *v) {
    if (!v->view) return;
    if (v->bench == 3 && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        g_message("bench: an edit to the load of its slice: %.0f ms", (g_get_monotonic_time() - v->bench_edit) / 1000.0);
        v->bench = 4;
        /* Then a move of part 0 by 5 mm: the log gives its history commit. */
        zs_part part;
        if (zs_app_part_get(zg_model_core(v->model), 0, &part) == ZS_OK) zg_model_part_move(v->model, 0, part.x + 5, part.y);
    }
    zs_view_set_mode(v->view, v->mode);
    gint64 t_load = g_get_monotonic_time();
    int rc = zs_view_load(v->view, zg_model_core(v->model));
    if (g_getenv("ZSLICE_BENCH_LOAD")) g_message("bench: zs_view_load %.1f ms", (g_get_monotonic_time() - t_load) / 1000.0);
    if (rc != ZS_OK) {
        g_warning("zslice: the 3D view did not load the toolpaths: %s", zg_status_text(rc));
        return;
    }
    zg_bed_model_update(v->view, zg_model_core(v->model));
    /* The other plates of the set, in a row beside the active plate. */
    zs_set_view_sync(zg_model_plate_set(v->model), v->view);
    zs_view_set_layer_range(v->view, v->layer_lo, v->layer);
    gint64 sel = zg_model_selected(v->model);
    zs_view_highlight(v->view, sel < 0 ? (size_t)-1 : (size_t)sel);
    zg_support_loaded(v->support);
    relight(v);
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
    if (g_getenv("ZSLICE_RING_DRAG") && !v->ring_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE &&
        zg_model_selected_part(v->model) >= 0) {
        v->ring_hook = TRUE;
        g_timeout_add_once(1000, ring_drag_hook, v);
    }
    if (g_getenv("ZSLICE_GRAB") && !v->grab_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->grab_hook = TRUE;
        g_timeout_add_once(1000, grab_hook, v);
    }
    if (g_getenv("ZSLICE_DOUBLE_CLICK") && !v->dbl_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->dbl_hook = TRUE;
        g_timeout_add_once(1000, dbl_hook_fire, v);
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
    /* For tests: ZSLICE_MENU=x,y opens the context menu at that pixel of
     * the 3D view, 1 s after the first slice. */
    /* For tests: ZSLICE_SELECT_TEST runs the Select tool 1 s after the
     * first slice (see select_hook). */
    if (g_getenv("ZSLICE_SELECT_TEST") && !v->select_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->select_hook = TRUE;
        g_timeout_add_once(1000, select_hook, v);
    }
    if (g_getenv("ZSLICE_MENU") && !v->menu_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->menu_hook = TRUE;
        g_timeout_add_once(1000, menu_hook, v);
    }
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

/* The view follows the dark mode of the theme (zg_theme_dark): the
 * background, the grid, and the bed. */
static void apply_dark(gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_view_set_dark(v->view, zg_theme_dark(v->area) ? 1 : 0);
    queue_frame(v);
}

static void on_map(GtkWidget *w, gpointer data) {
    View3d *v = data;
    v->hidden = FALSE;
    zg_support_set_shown(v->support, TRUE);
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
    gint64 t0 = g_get_monotonic_time();
    int rc = zs_view_new(zg_native_surface_handle(v->native), (uint32_t)width, (uint32_t)height, &v->view);
    if (g_getenv("ZSLICE_BENCH"))
        g_message("bench: the 3D view started %.0f ms after the start (Vulkan: %.0f ms)", (g_get_monotonic_time() - zg_start_us) / 1000.0,
                  (g_get_monotonic_time() - t0) / 1000.0);
    if (rc != ZS_OK) {
        g_free(v->error);
        v->error = g_strdup_printf("the 3D view did not start: %s", zg_status_text(rc));
        zg_native_surface_free(v->native);
        v->native = NULL;
        v->view = NULL;
        gtk_widget_queue_draw(w);
        return;
    }
    zg_support_set_view(v->support, v->view);
    if (g_getenv("ZSLICE_BENCH")) v->bench = 1;
    apply_dark(v);
    load_data(v);
    sync_geometry(v);
    if (v->has_pending_camera) {
        zs_view_set_camera(v->view, v->pending_camera);
        v->has_pending_camera = FALSE;
    }
}

/* The camera of the view, for a session: 8 floats. FALSE with no view. */
gboolean zg_view3d_get_camera(GtkWidget *view, float out[8]) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v) return FALSE;
    if (!v->view) {
        if (!v->has_pending_camera) return FALSE;
        memcpy(out, v->pending_camera, sizeof v->pending_camera);
        return TRUE;
    }
    zs_view_get_camera(v->view, out);
    return TRUE;
}

/* Sets the camera of a session: at once, or when the view starts. */
void zg_view3d_set_camera(GtkWidget *view, const float in[8]) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v) return;
    memcpy(v->pending_camera, in, sizeof v->pending_camera);
    v->has_pending_camera = TRUE;
    if (v->view) {
        zs_view_set_camera(v->view, in);
        v->has_pending_camera = FALSE;
        gtk_widget_queue_draw(v->area);
    }
}

static void on_unmap(GtkWidget *w, gpointer data) {
    View3d *v = data;
    v->hidden = TRUE;
    zg_support_release(v->support);
    zg_support_set_shown(v->support, FALSE);
    /* No frame clock ticks while unmapped: stop the animation. */
    if (v->anim) gtk_widget_remove_tick_callback(v->area, v->anim);
    v->anim = 0;
    if (v->idle) {
        g_source_remove(v->idle);
        v->idle = 0;
    }
    if (v->native) zg_native_surface_hide(v->native);
    /* No frames: a fall ends at once. */
    if (v->fall_tick) fall_finish(v);
}

static void on_resize(GtkDrawingArea *area, int width, int height, gpointer data) {
    sync_geometry(data);
}

/* Draws only a message if the view could not start. Otherwise the widget
 * stays transparent. */
static const char *const axis_names[] = {"X", "Y", "Z"};

/* The core view draws the rings. Here: the label of a turn. */
static void draw_rings(View3d *v, cairo_t *cr) {
    if (v->turn_axis < 0) return;
    /* The turn of the drag, next to the pointer. */
    char text[48];
    double deg = v->turn_want;
    g_snprintf(text, sizeof text, "%s%.0f° about %s", deg > 0 ? "+" : "", deg, axis_names[v->turn_axis]);
    PangoLayout *layout = gtk_widget_create_pango_layout(v->area, text);
    int tw, th;
    pango_layout_get_pixel_size(layout, &tw, &th);
    double x = v->turn_px + 16, y = v->turn_py - 30;
    cairo_set_source_rgba(cr, 0.12, 0.13, 0.15, 0.85);
    cairo_rectangle(cr, x - 6, y - 3, tw + 12, th + 6);
    cairo_fill(cr);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

static void draw_message(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    View3d *v = data;
    if (!v->error) {
        if (v->rings_on) draw_rings(v, cr);
        return;
    }
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

void zg_view3d_set_cut(GtkWidget *view, double x0, double y0, double x1, double y1, double z) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    zs_view_set_cut(v->view, x0, y0, x1, y1, z);
    queue_frame(v);
}

gboolean zg_view3d_moving(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && (v->anim || v->fall_tick || v->hand || v->bench == 2);
}

gboolean zg_view3d_path_rect(GtkWidget *view, gint64 path, double out[4]) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    float r[4];
    if (!v || !v->view || v->hidden || path < 0 || !zs_view_path_rect(v->view, (size_t)path, r)) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    for (int k = 0; k < 4; k++) out[k] = r[k] / s;
    return TRUE;
}

gboolean zg_view3d_pixel_of(GtkWidget *view, double x, double y, double z, double *px, double *py) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    float qx, qy;
    if (!v || !v->view || v->hidden || !zs_view_pixel_of(v->view, x, y, z, &qx, &qy)) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    *px = qx / s;
    *py = qy / s;
    return TRUE;
}

static void on_hook_owner_gone(GtkWidget *owner, gpointer data) {
    View3d *v = data;
    for (guint i = 0; v->hooks && i < v->hooks->len;) {
        if (g_array_index(v->hooks, FrameHook, i).owner == owner) g_array_remove_index(v->hooks, i);
        else i++;
    }
}

void zg_view3d_on_frame(GtkWidget *view, GtkWidget *owner, void (*fn)(gpointer), gpointer data) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v) return;
    if (!v->hooks) v->hooks = g_array_new(FALSE, FALSE, sizeof(FrameHook));
    FrameHook h = {owner, fn, data};
    g_array_append_val(v->hooks, h);
    g_signal_connect(owner, "destroy", G_CALLBACK(on_hook_owner_gone), v);
}

/* ---- the rings of the Turn tool ---- */

/* The rings around the selected part: the core view draws them, and finds
 * the ring under a pixel (zs_view_set_rings, zs_view_ring_at). */
static void compute_rings(View3d *v) {
    gboolean was = v->rings_on;
    v->rings_on = FALSE;
    gint64 i = zg_model_selected_part(v->model);
    zs_part p;
    if (v->view && zg_model_tool(v->model) == ZG_TOOL_TURN && i >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) == ZS_OK) {
        zs_view_set_rings(v->view, p.x, p.y, p.size_z / 2, 0.62 * MAX(p.size_x, MAX(p.size_y, p.size_z)) + 4);
        v->rings_on = TRUE;
    } else if (was && v->view) {
        zs_view_set_rings(v->view, 0, 0, 0, 0);
    }
    if (was != v->rings_on) queue_frame(v);
}

/* The ring under the point x, y (within 8 points), or -1. */
static int ring_at(View3d *v, double x, double y) {
    compute_rings(v);
    if (!v->rings_on) return -1;
    int s = gtk_widget_get_scale_factor(v->area);
    return zs_view_ring_at(v->view, (float)(x * s), (float)(y * s), 8.0f * s);
}

/* One step of a ring drag to the core: the turn since the last step. The
 * part slices again at once. */
static void turn_send(View3d *v) {
    gint64 i = zg_model_selected_part(v->model);
    double step = v->turn_want - v->turn_sent;
    if (i < 0 || step == 0) return;
    v->turn_sent = v->turn_want;
    if (v->turn_axis == 2) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) == ZS_OK) zg_model_part_rotate(v->model, (size_t)i, p.rotation + step);
    } else {
        zg_model_part_turn(v->model, (size_t)i, v->turn_axis, step);
    }
}

/* A press on a ring at x, y starts a turn. FALSE if no ring is there. The
 * slices wait for the end of the drag. */
static gboolean ring_press(View3d *v, double x, double y) {
    int a = ring_at(v, x, y);
    if (a < 0) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    if (!zs_view_ring_press(v->view, a, (float)(x * s), (float)(y * s))) return FALSE;
    v->turn_axis = a;
    v->turn_want = v->turn_sent = 0;
    v->turn_px = x;
    v->turn_py = y;
    zg_model_hold(v->model, TRUE);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
    return TRUE;
}

/* The pointer of a ring drag is at x, y: the part turns in steps (the core
 * gives the angle, in the sense of the ring on the screen). */
static void ring_move(View3d *v, double x, double y, gboolean fine) {
    v->turn_px = x;
    v->turn_py = y;
    int s = gtk_widget_get_scale_factor(v->area);
    v->turn_want = round(zs_view_ring_drag(v->view, (float)(x * s), (float)(y * s), fine ? 5 : 15));
    turn_send(v);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

/* The end of a ring drag: the part slices once. */
static void ring_release(View3d *v) {
    if (v->turn_axis < 0) return;
    v->turn_axis = -1;
    if (v->view) zs_view_ring_release(v->view);
    /* The release slices; a part that cannot stand as turned falls
     * (the model's "fall"). */
    zg_model_hold(v->model, FALSE);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

/* For tests: ZSLICE_RING_DRAG=x0,y0,x1,y1 drags from x0, y0 to x1, y1 in
 * 12 steps (one each 50 ms), with the Turn tool. */
typedef struct {
    View3d *v;
    double x0, y0, x1, y1;
    int step;
} RingDrag;

static gboolean ring_drag_step(gpointer data) {
    RingDrag *d = data;
    View3d *v = d->v;
    if (d->step == 0 && !ring_press(v, d->x0, d->y0)) {
        g_message("ring drag: no ring at %.0f, %.0f", d->x0, d->y0);
        g_free(d);
        return G_SOURCE_REMOVE;
    }
    d->step++;
    double t = d->step / 12.0;
    ring_move(v, d->x0 + (d->x1 - d->x0) * t, d->y0 + (d->y1 - d->y0) * t, FALSE);
    if (d->step < 12) return G_SOURCE_CONTINUE;
    g_message("ring drag: axis %d, %.0f degrees", v->turn_axis, v->turn_want);
    /* The end of the drag: the label goes, and the part slices. */
    ring_release(v);
    g_free(d);
    return G_SOURCE_REMOVE;
}

static void ring_drag_hook(gpointer data) {
    View3d *v = data;
    /* "auto": from the point of the rings at +X to the point at +Y. */
    if (strcmp(g_getenv("ZSLICE_RING_DRAG"), "auto") == 0) {
        gint64 i = zg_model_selected_part(v->model);
        zs_part p;
        if (i < 0 || zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) != ZS_OK) return;
        double r = 0.62 * MAX(p.size_x, MAX(p.size_y, p.size_z)) + 4;
        RingDrag *d = g_new0(RingDrag, 1);
        d->v = v;
        if (!zg_view3d_pixel_of(v->area, p.x + r, p.y, p.size_z / 2, &d->x0, &d->y0) ||
            !zg_view3d_pixel_of(v->area, p.x, p.y + r, p.size_z / 2, &d->x1, &d->y1)) {
            g_free(d);
            return;
        }
        zg_model_set_tool(v->model, ZG_TOOL_TURN);
        g_timeout_add(50, ring_drag_step, d);
        return;
    }
    char **f = g_strsplit(g_getenv("ZSLICE_RING_DRAG"), ",", 4);
    if (g_strv_length(f) == 4) {
        RingDrag *d = g_new0(RingDrag, 1);
        d->v = v;
        d->x0 = g_ascii_strtod(f[0], NULL);
        d->y0 = g_ascii_strtod(f[1], NULL);
        d->x1 = g_ascii_strtod(f[2], NULL);
        d->y1 = g_ascii_strtod(f[3], NULL);
        zg_model_set_tool(v->model, ZG_TOOL_TURN);
        g_timeout_add(50, ring_drag_step, d);
    }
    g_strfreev(f);
}

/* The mouse, as in Cura: a right drag orbits (turn and tilt, the bed
 * stays level), as a left drag does; a middle drag, or Shift and a drag,
 * pans; and the scroll wheel zooms toward the pointer. On a touchpad: two
 * fingers clicked down and slid pan (a right drag after a touchpad
 * scroll), and a light two-finger swipe or a pinch zooms. */
enum { DRAG_ORBIT, DRAG_PAN, DRAG_RIGHT };

/* ---- the fall of a part, and the hand ---- */

static gboolean on_fall_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    View3d *v = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    double dt = v->fall_last ? (now - v->fall_last) / 1e6 : 1.0 / 60;
    v->fall_last = now;
    double f[10];
    int rc = zg_model_fall_step(v->model, MIN(dt, 0.05), f);
    /* The frame at rest sets no preview: the slice of the new place ends
     * the preview, and a preview after it moves the new beads again. */
    if (rc == 1 && v->view)
        zs_view_part_preview(v->view, (int)v->fall_part, (float)f[0], (float)f[1], (float)f[2], (float)f[3], (float)f[4], (float)f[5],
                             (float)f[6], (float)f[7], (float)f[8], (float)f[9], 0);
    queue_frame(v);
    if (rc == 1) return G_SOURCE_CONTINUE;
    if (rc < 0 && v->view) zs_view_part_preview(v->view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
    v->fall_tick = 0;
    v->hand = FALSE;
    return G_SOURCE_REMOVE;
}

static void fall_run(View3d *v, gint64 part) {
    v->fall_part = part;
    v->fall_last = 0;
    if (!v->fall_tick) v->fall_tick = gtk_widget_add_tick_callback(v->area, on_fall_tick, v, NULL);
}

/* With no frames (the view is hidden), the fall runs to its end at once. */
static void fall_finish(View3d *v) {
    if (v->fall_tick) gtk_widget_remove_tick_callback(v->area, v->fall_tick);
    v->fall_tick = 0;
    if (v->hand) zg_model_grab_end(v->model);
    v->hand = FALSE;
    double f[10];
    for (int k = 0; k < 6000 && zg_model_fall_step(v->model, 1.0 / 60, f) == 1; k++) {}
    if (zg_model_falling(v->model)) zg_model_fall_cancel(v->model);
}

/* A part that lost what held it (the model's "fall"). */
static void on_fall(ZgModel *model, gint64 part, gpointer data) {
    View3d *v = data;
    if (!zg_model_fall_start(model, (size_t)part)) return;
    if (v->view && !v->hidden) fall_run(v, part);
    else fall_finish(v);
}

/* The hand moves to the pixel x, y: on the level plane at its height. */
static void hand_move(View3d *v, double x, double y) {
    v->hand_px = x;
    v->hand_py = y;
    int s = gtk_widget_get_scale_factor(v->area);
    double bx, by;
    if (zs_view_plane_point(v->view, (float)(x * s), (float)(y * s), v->hand_h, &bx, &by)) zg_model_grab_move(v->model, bx, by, v->hand_h);
}

static gint64 part_at(View3d *v, double x, double y, double *bx, double *by);

/* A press of the Grab tool: the hand takes the part at the point under
 * the pointer, and holds it 15 mm over that point. */
static gboolean hand_start(View3d *v, double x, double y) {
    if (zg_model_falling(v->model)) return FALSE;
    gint64 part = part_at(v, x, y, NULL, NULL);
    int s = gtk_widget_get_scale_factor(v->area);
    double p[3];
    if (part < 0 || !zs_view_surface_point(v->view, (float)(x * s), (float)(y * s), 0, p)) return FALSE;
    if (!zg_model_grab_start(v->model, (size_t)part, p[0], p[1], p[2])) return FALSE;
    v->hand = TRUE;
    v->hand_h = p[2] + 15;
    v->yaw = v->tilt = v->yaw_sent = v->tilt_sent = 0;
    hand_move(v, x, y);
    fall_run(v, part);
    return TRUE;
}

/* Alt and a drag turn the part in the hand: half a degree for each pixel,
 * about the vertical (x) and about the level axis of the screen (y).
 * Shift: steps of 15 degrees. */
static void hand_turn(View3d *v, double dx, double dy, gboolean snap) {
    v->yaw += dx * 0.5;
    v->tilt += dy * 0.5;
    double yaw = (snap ? round(v->yaw / 15) * 15 : v->yaw) - v->yaw_sent;
    double tilt = (snap ? round(v->tilt / 15) * 15 : v->tilt) - v->tilt_sent;
    if (yaw != 0) zg_model_grab_turn(v->model, 0, 0, 1, yaw);
    if (tilt != 0) {
        int s = gtk_widget_get_scale_factor(v->area);
        double ax, ay, bx, by;
        float px = (float)(v->hand_px * s), py = (float)(v->hand_py * s);
        if (zs_view_plane_point(v->view, px, py, v->hand_h, &ax, &ay) && zs_view_plane_point(v->view, px + 50, py, v->hand_h, &bx, &by))
            zg_model_grab_turn(v->model, bx - ax, by - ay, 0, tilt);
    }
    v->yaw_sent += yaw;
    v->tilt_sent += tilt;
}

/* The hand lets go: the part keeps its speed, falls, and rests. */
static gboolean hand_release(View3d *v) {
    if (!v->hand) return FALSE;
    zg_model_grab_end(v->model);
    v->hand = FALSE;
    set_cursor(v, zg_model_tool(v->model) == ZG_TOOL_GRAB ? "grab" : NULL);
    return TRUE;
}

gboolean zg_view3d_hand_release(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && hand_release(v);
}

/* A move of the pointer with the part in the hand: Alt turns it, else it
 * goes along. */
static void hand_pointer(View3d *v, double x, double y, GdkModifierType mods) {
    if (mods & GDK_ALT_MASK) {
        if (!v->turning) {
            v->turning = TRUE;
            v->yaw = v->tilt = v->yaw_sent = v->tilt_sent = 0;
            v->turn_x = x;
            v->turn_y = y;
        }
        hand_turn(v, x - v->turn_x, y - v->turn_y, (mods & GDK_SHIFT_MASK) != 0);
        v->turn_x = x;
        v->turn_y = y;
        return;
    }
    /* After a turn, the hand moves on from here: no jump. */
    v->turning = FALSE;
    hand_move(v, x, y);
}

/* The wheel lifts the part in the hand (mm), from the bed to 200 mm. */
static void hand_lift(View3d *v, double mm) {
    v->hand_h = CLAMP(v->hand_h + mm, 1, 200);
    hand_move(v, v->hand_px, v->hand_py);
}

/* For tests: ZSLICE_GRAB=x0,y0,x1,y1[,turn] takes the part at the pixel
 * x0, y0 with the Grab tool, carries it to x1, y1 in 12 steps (one each
 * 50 ms), turns it `turn` degrees about Z on the way, and lets go. The log
 * gives the place of each part 3 s later. */
typedef struct {
    View3d *v;
    double f[5];
    int step;
} GrabDrag;

static void grab_log(gpointer data) {
    View3d *v = data;
    zs_part p;
    for (size_t i = 0; zs_app_part_get(zg_model_core(v->model), i, &p) == ZS_OK; i++)
        g_message("grab: part %zu at %.1f, %.1f, size %.1f x %.1f x %.1f, %s", i, p.x, p.y, p.size_x, p.size_y, p.size_z,
                  zg_model_falling(v->model) ? "falling" : "at rest");
}

static gboolean grab_step(gpointer data) {
    GrabDrag *d = data;
    View3d *v = d->v;
    if (d->step == 0) {
        zg_model_set_tool(v->model, ZG_TOOL_GRAB);
        if (!hand_start(v, d->f[0], d->f[1])) {
            g_message("grab: no part at %.0f, %.0f", d->f[0], d->f[1]);
            g_free(d);
            return G_SOURCE_REMOVE;
        }
    }
    d->step++;
    double t = d->step / 12.0;
    if (d->f[4] != 0) hand_turn(v, d->f[4] / 12 * 2, 0, FALSE);
    hand_move(v, d->f[0] + (d->f[2] - d->f[0]) * t, d->f[1] + (d->f[3] - d->f[1]) * t);
    if (d->step < 12) return G_SOURCE_CONTINUE;
    hand_release(v);
    g_timeout_add_once(3000, grab_log, v);
    g_free(d);
    return G_SOURCE_REMOVE;
}

static void grab_hook(gpointer data) {
    char **f = g_strsplit(g_getenv("ZSLICE_GRAB"), ",", 5);
    guint n = g_strv_length(f);
    if (n >= 4) {
        GrabDrag *d = g_new0(GrabDrag, 1);
        d->v = data;
        for (guint i = 0; i < n; i++) d->f[i] = g_ascii_strtod(f[i], NULL);
        g_timeout_add(50, grab_step, d);
    }
    g_strfreev(f);
}

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

/* The frame of each selected part on the bed. */
static void show_part_box(View3d *v) {
    if (!v->view) return;
    guint n = 0;
    const gint64 *list = zg_model_parts(v->model, &n);
    double *boxes = g_new(double, 4 * (n > 0 ? n : 1));
    size_t k = 0;
    for (guint i = 0; i < n; i++) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(v->model), (size_t)list[i], &p) != ZS_OK) continue;
        double *b = boxes + 4 * k++;
        b[0] = p.x - p.size_x / 2;
        b[1] = p.y - p.size_y / 2;
        b[2] = p.x + p.size_x / 2;
        b[3] = p.y + p.size_y / 2;
    }
    zs_view_part_boxes(v->view, boxes, k);
    g_free(boxes);
    queue_frame(v);
}

static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    show_part_box(data);
}

/* A change of the plates of the set (ZS_EVENT_PLATES: a plate added, gone,
 * or sliced in the background): the row of the other plates again. */
static void on_plates_sync(ZgModel *model, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_set_view_sync(zg_model_plate_set(model), v->view);
    queue_frame(v);
}

static void on_plate_changed(ZgModel *model, gpointer data) {
    show_part_box(data);
}

/* The cursor of the tool: a cross for the measure tape and the Support
 * tool. */
static void set_cursor(View3d *v, const char *name) {
    if (v->cursor == name) return;
    v->cursor = name;
    gtk_widget_set_cursor_from_name(v->area, name);
}

static void tool_cursor(View3d *v) {
    ZgTool t = zg_model_tool(v->model);
    set_cursor(v, t == ZG_TOOL_MEASURE || t == ZG_TOOL_SUPPORT ? "crosshair" : t == ZG_TOOL_GRAB ? "grab" : NULL);
}

static void on_tool_changed(ZgModel *model, gpointer data) {
    View3d *v = data;
    if (zg_model_tool(model) != ZG_TOOL_GRAB) hand_release(v);
    tool_cursor(v);
    /* The Support tool: the support lines faint, or solid again. */
    apply_focus(v);
    /* The rings show or go. */
    queue_frame(data);
}

static void on_measure_changed(ZgModel *model, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    const double *pts = NULL;
    int n = zg_model_measure(model, &pts);
    zs_view_set_measure(v->view, (size_t)n, pts);
    queue_frame(v);
}

/* ---- a range of layers: a drag of the Select tool (range-card.h) ---- */

/* The other lines of the multiple selection of the model, in the view. */
static void more_from_model(View3d *v) {
    guint n = 0;
    const gint64 *more = zg_model_more(v->model, &n);
    size_t *list = g_new(size_t, n + 1);
    size_t k = 0;
    for (guint i = 0; i < n; i++) if (more[i] >= 0) list[k++] = (size_t)more[i];
    zs_view_highlight_more(v->view, list, k);
    g_free(list);
}

/* Lights layers lo to hi: from line `path`, its body of its part on them
 * (zs_view_light_connected); with no line (-1), all their lines. */
static void light_range(View3d *v, gint64 path, size_t lo, size_t hi) {
    zs_view_light_layers(v->view, 1, 0);
    v->run_lit = FALSE;
    v->light_on = TRUE;
    v->light_path = path;
    v->light_layer = path >= 0 ? zs_app_path_layer(zg_model_core(v->model), (size_t)path) : -1;
    v->light_lo = MIN(lo, hi);
    v->light_hi = MAX(lo, hi);
    if (path < 0 || zs_view_light_connected(v->view, (size_t)path, v->light_lo, v->light_hi, NULL) != ZS_OK)
        zs_view_light_layers(v->view, v->light_lo, v->light_hi);
}

/* After a new load (a slice, or the simulated print after it): the lit
 * range again, from its start line if that line is still on its layer,
 * else all the lines of the layers. */
static void relight(View3d *v) {
    if (!v->light_on || !zg_range_card_open(zg_range_card_of(v->area))) return;
    gint64 path = v->light_path;
    if (path >= 0 && zs_app_path_layer(zg_model_core(v->model), (size_t)path) != v->light_layer) path = -1;
    if (path < 0 || zs_view_light_connected(v->view, (size_t)path, v->light_lo, v->light_hi, NULL) != ZS_OK)
        zs_view_light_layers(v->view, v->light_lo, v->light_hi);
    if (g_getenv("ZSLICE_SELECT_TEST"))
        g_message("select test: lit again after a load, %s (line %" G_GINT64_FORMAT ", layer %td)", path >= 0 ? "the body" : "the layers",
                  v->light_path, v->light_layer);
}

/* The layer under the pointer at x, y in a drag over layers: the pointer
 * goes to the nearest point of the line on the screen from the bed to the
 * top layer shown, up through the point of the press. Two projections for
 * each move, and no pick. A view from above (a short line) picks the line
 * under the pointer. */
static gboolean range_layer_at(View3d *v, double x, double y, size_t *out) {
    zs_toolpaths tp;
    if (zs_app_toolpaths(zg_model_core(v->model), &tp) != ZS_OK || tp.layer_count == 0) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    size_t lo = MIN(v->layer_lo, tp.layer_count - 1), hi = MIN(v->layer, tp.layer_count - 1);
    float ax, ay, bx, by;
    gboolean ok = zs_view_pixel_of(v->view, v->range_pt[0], v->range_pt[1], 0, &ax, &ay) &&
                  zs_view_pixel_of(v->view, v->range_pt[0], v->range_pt[1], tp.layer_z[hi], &bx, &by);
    double len2 = ok ? (bx - ax) * (bx - ax) + (by - ay) * (by - ay) : 0;
    double px = x * s, py = y * s;
    if (len2 < 24.0 * s * 24.0 * s) {
        size_t path = zs_view_pick(v->view, (float)px, (float)py);
        if (path == (size_t)-1) return FALSE;
        *out = zs_view_path_layer(v->view, path);
        return TRUE;
    }
    double t = ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len2;
    double want = CLAMP(t, 0, 1) * tp.layer_z[hi];
    /* The first layer with its top at or over the height. */
    size_t l = lo, h = hi;
    while (l < h) {
        size_t m = (l + h) / 2;
        if (tp.layer_z[m] < want) l = m + 1;
        else h = m;
    }
    *out = l;
    return TRUE;
}

/* A press of the Select tool: on a printed line, the start of a drag over
 * layers. */
static gboolean range_start(View3d *v, double x, double y) {
    int s = gtk_widget_get_scale_factor(v->area);
    size_t path = zs_view_pick(v->view, (float)(x * s), (float)(y * s));
    double p[3];
    if (path == (size_t)-1 || !zs_view_surface_point(v->view, (float)(x * s), (float)(y * s), 0, p)) return FALSE;
    v->range_on = TRUE;
    v->range_lit = FALSE;
    v->range_layer = v->range_cur = zs_view_path_layer(v->view, path);
    v->range_path = path;
    v->range_pt[0] = p[0];
    v->range_pt[1] = p[1];
    return TRUE;
}

static void range_move(View3d *v, double x, double y) {
    size_t l;
    if (!range_layer_at(v, x, y, &l) || (v->range_lit && l == v->range_cur)) return;
    if (!v->range_lit) {
        /* The drag is for the layers: no line, no support, and no card of
         * an old range. */
        zg_model_select(v->model, -1);
        zg_support_clear_pick(v->support);
        zg_range_card_close(zg_range_card_of(v->area));
    }
    v->range_lit = TRUE;
    v->range_cur = l;
    /* The body of the part of the line of the press, on these layers. */
    light_range(v, (gint64)v->range_path, v->range_layer, l);
    queue_frame(v);
}

void zg_view3d_light_clear(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    v->light_on = FALSE;
    v->key_on = FALSE;
    zs_view_light_layers(v->view, 1, 0);
    more_from_model(v);
    queue_frame(v);
}

/* Shift+K (dir 1) and Shift+J (dir -1): a range of layers that grows from
 * the layer of the selected line (or the top layer shown), as a drag of
 * the Select tool makes. The card of the range opens on it. */
void zg_view3d_key_range(GtkWidget *view, int dir) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    zs_app *core = zg_model_core(v->model);
    zs_toolpaths tp;
    GtkWidget *card = zg_range_card_of(v->area);
    if (!card || zs_app_toolpaths(core, &tp) != ZS_OK || tp.layer_count == 0) return;
    if (!v->key_on || !zg_range_card_open(card)) {
        gint64 sel = zg_model_selected(v->model);
        ptrdiff_t l = sel >= 0 ? zs_app_path_layer(core, (size_t)sel) : -1;
        v->key_a = v->key_b = l >= 0 ? (size_t)l : MIN(v->layer, tp.layer_count - 1);
        v->key_path = l >= 0 ? sel : -1;
    }
    long b = (long)v->key_b + dir;
    v->key_b = (size_t)CLAMP(b, 0, (long)tp.layer_count - 1);
    size_t lo = MIN(v->key_a, v->key_b), hi = MAX(v->key_a, v->key_b);
    zg_range_card_show(card, lo, hi);
    light_range(v, v->key_path, lo, hi);
    v->key_on = TRUE;
    queue_frame(v);
}

gboolean zg_view3d_bounds(GtkWidget *view, double out[4]) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && v->view && zs_view_bounds(v->view, out) == ZS_OK;
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    View3d *v = data;
    v->drag_x = 0;
    v->drag_y = 0;
    v->moving = -1;
    v->tape_end = -1;
    v->turn_axis = -1;
    v->range_on = FALSE;
    /* The measure tape: a left drag on an end of it moves that end. */
    int mode0 = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    /* The Turn tool: a drag along a ring turns the part. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_TURN && ring_press(v, x, y)) {
        set_cursor(v, "grabbing");
        return;
    }
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_MEASURE) {
        const double *m = NULL;
        int n = zg_model_measure(v->model, &m);
        int s = gtk_widget_get_scale_factor(v->area);
        double best = 14.0 * s;
        for (int i = 0; i < n; i++) {
            float qx, qy;
            if (!zs_view_pixel_of(v->view, m[3 * i], m[3 * i + 1], m[3 * i + 2], &qx, &qy)) continue;
            double d = hypot(qx - x * s, qy - y * s);
            if (d < best) {
                best = d;
                v->tape_end = i;
            }
        }
        if (v->tape_end >= 0) {
            set_cursor(v, "grabbing");
            return;
        }
    }
    /* The Grab tool: a click on a part picks it up; the next click lets
     * go. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_GRAB) {
        if (hand_release(v)) {
            v->hand_click = TRUE;
            return;
        }
        if (hand_start(v, x, y)) {
            v->hand_click = TRUE;
            v->turning = FALSE;
            set_cursor(v, "grabbing");
            return;
        }
    }
    /* The Support tool: a press on a point of an area drags it. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_SUPPORT && zg_support_press(v->support, x, y)) {
        set_cursor(v, "grabbing");
        return;
    }
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    /* The Select tool: a press on a dot of a picked support tree drags
     * it; a press on a printed line starts a drag over layers. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_SELECT && !(mods & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK))) {
        if (zg_support_picked(v->support) && zg_support_press(v->support, x, y)) {
            set_cursor(v, "grabbing");
            return;
        }
        if (range_start(v, x, y)) {
            set_cursor(v, "ns-resize");
            return;
        }
    }
    /* Ctrl and the left button on a part: move the part. */
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    if (v->view && mode == DRAG_ORBIT && ((mods & GDK_CONTROL_MASK) || zg_model_tool(v->model) == ZG_TOOL_MOVE)) {
        double bx, by;
        gint64 part = part_at(v, x, y, &bx, &by);
        zs_part p;
        if (part >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)part, &p) == ZS_OK) {
            /* A part of a selection of several parts: they all move. */
            guint n = 0;
            const gint64 *list = zg_model_parts(v->model, &n);
            gboolean in = FALSE;
            for (guint i = 0; i < n; i++) in = in || list[i] == part;
            if (!v->group) {
                v->group = g_array_new(FALSE, FALSE, sizeof(gint64));
                v->group_xy = g_array_new(FALSE, FALSE, sizeof(double));
            }
            g_array_set_size(v->group, 0);
            g_array_set_size(v->group_xy, 0);
            if (in && n > 1) {
                for (guint i = 0; i < n; i++) {
                    zs_part q;
                    if (zs_app_part_get(zg_model_core(v->model), (size_t)list[i], &q) != ZS_OK) continue;
                    g_array_append_val(v->group, list[i]);
                    g_array_append_val(v->group_xy, q.x);
                    g_array_append_val(v->group_xy, q.y);
                }
            } else {
                zg_model_select_part(v->model, part);
            }
            v->moving = part;
            v->move_x0 = p.x;
            v->move_y0 = p.y;
            v->bed_x0 = bx;
            v->bed_y0 = by;
            set_cursor(v, "move");
            return;
        }
    }
    set_cursor(v, "grabbing");
}

static void menu_at(View3d *v, double x, double y);
static gboolean path_point(View3d *v, gint64 path, gint64 seg, double *x, double *y, double *z);
static void popup_menu(View3d *v, GMenu *menu, double x, double y);

static void on_drag_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    View3d *v = data;
    v->moving = -1;
    v->tape_end = -1;
    /* The hand keeps the part after the release of its click. */
    if (v->hand_click) {
        v->hand_click = FALSE;
        return;
    }
    ring_release(v);
    zg_support_release(v->support);
    tool_cursor(v);
    /* The end of a drag over layers: the card of the range. */
    if (v->range_on) {
        v->range_on = FALSE;
        GtkWidget *card = zg_range_card_of(v->area);
        if (v->range_lit && card) zg_range_card_show(card, MIN(v->range_layer, v->range_cur), MAX(v->range_layer, v->range_cur));
        return;
    }
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    if (mode == DRAG_RIGHT && fabs(dx) < 4 && fabs(dy) < 4) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        /* On a dot of a picked support tree: its own menu. */
        if (zg_support_menu_at(v->support, sx, sy)) {
            GMenu *menu = g_menu_new();
            g_menu_append(menu, "Delete branch", "view3d.delete-branch");
            popup_menu(v, menu, sx, sy);
            g_object_unref(menu);
            return;
        }
        menu_at(v, sx, sy);
    }
}

static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    View3d *v = data;
    int mode = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag"));
    int scale = gtk_widget_get_scale_factor(v->area);
    float ddx = (float)(dx - v->drag_x), ddy = (float)(dy - v->drag_y);
    if (v->turn_axis >= 0) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        ring_move(v, sx + dx, sy + dy, (mods & GDK_SHIFT_MASK) != 0);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    /* The click of the hand: the pointer moves carry the part. */
    if (v->hand_click) return;
    if (v->range_on) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        if (v->range_lit || fabs(dx) > 4 || fabs(dy) > 4) range_move(v, sx + dx, sy + dy);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (zg_support_dragging(v->support)) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        zg_support_drag(v->support, sx + dx, sy + dy, (mods & GDK_SHIFT_MASK) != 0);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (v->view && v->tape_end >= 0) {
        double sx, sy, p[3];
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        if (zs_view_surface_point(v->view, (float)((sx + dx) * scale), (float)((sy + dy) * scale), !(mods & GDK_SHIFT_MASK), p))
            zg_model_measure_move(v->model, v->tape_end, p[0], p[1], p[2]);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (v->view && v->moving >= 0) {
        /* The part follows the bed point under the pointer. */
        double sx, sy, bx, by;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        if (zs_view_bed_point(v->view, (float)((sx + dx) * scale), (float)((sy + dy) * scale), &bx, &by)) {
            if (v->group && v->group->len > 1) {
                /* The parts move by the same amount; the copy of the list
                 * stays, since each move changes the plate. */
                for (guint i = 0; i < v->group->len; i++) {
                    double *xy = &g_array_index(v->group_xy, double, 2 * i);
                    zg_model_part_move(v->model, (size_t)g_array_index(v->group, gint64, i), xy[0] + bx - v->bed_x0, xy[1] + by - v->bed_y0);
                }
            } else {
                zg_model_part_move(v->model, (size_t)v->moving, v->move_x0 + bx - v->bed_x0, v->move_y0 + by - v->bed_y0);
            }
        }
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (v->view) {
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        /* A right drag: a mouse orbits (as in Cura); two fingers clicked
         * down on a touchpad pan. Both come as the right button, so the
         * last scroll tells the device. */
        if (mode == DRAG_PAN || (mode == DRAG_RIGHT && v->touchpad) || (mods & GDK_SHIFT_MASK)) zs_view_pan(v->view, ddx * scale, ddy * scale);
        else zs_view_orbit(v->view, ddx, ddy);
    }
    v->drag_x = dx;
    v->drag_y = dy;
    queue_frame(v);
}

static void on_motion(GtkEventControllerMotion *c, double x, double y, gpointer data) {
    View3d *v = data;
    v->pointer_x = x;
    v->pointer_y = y;
    if (v->hand) {
        hand_pointer(v, x, y, gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c)));
        return;
    }
    /* The Support tool: a hand over a point of an area. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c));
    gboolean pressed = (mods & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)) != 0;
    if (zg_model_tool(v->model) == ZG_TOOL_SUPPORT && v->view && !pressed) {
        set_cursor(v, zg_support_cursor(v->support, x, y));
        zg_support_hover(v->support, x, y);
    } else if (zg_model_tool(v->model) == ZG_TOOL_SELECT && v->view && !pressed && zg_support_picked(v->support)) {
        set_cursor(v, zg_support_cursor(v->support, x, y));
    }
}

/* A pinch on a touchpad: zoom toward the pointer, by the change of the
 * scale since the event before. */
static double pinch_scale = 1;

static void on_pinch_begin(GtkGesture *g, GdkEventSequence *seq, gpointer data) {
    pinch_scale = 1;
}

static void on_pinch(GtkGestureZoom *g, double scale, gpointer data) {
    View3d *v = data;
    if (!v->view || scale <= 0) return;
    int s = gtk_widget_get_scale_factor(v->area);
    zs_view_zoom_at(v->view, (float)(pinch_scale / scale), (float)(v->pointer_x * s), (float)(v->pointer_y * s));
    pinch_scale = scale;
    queue_frame(v);
}

static gboolean on_scroll(GtkEventControllerScroll *c, double dx, double dy, gpointer data) {
    View3d *v = data;
    int scale = gtk_widget_get_scale_factor(v->area);
    /* The device of the last scroll: a touchpad scrolls in pixels, a
     * mouse wheel in steps (see `touchpad`). */
    v->touchpad = gtk_event_controller_scroll_get_unit(c) == GDK_SCROLL_UNIT_SURFACE;
    /* Ctrl and the wheel: turn the selected part by 15 degrees a step. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c));
    /* The hand: the wheel lifts the part (10 mm a step, 0.1 mm a pixel of
     * a touchpad). */
    if (v->hand) {
        gboolean px = gtk_event_controller_scroll_get_unit(c) == GDK_SCROLL_UNIT_SURFACE;
        hand_lift(v, -dy * (px ? 0.1 : 10));
        return TRUE;
    }
    gint64 part = zg_model_selected_part(v->model);
    if (((mods & GDK_CONTROL_MASK) || zg_model_tool(v->model) == ZG_TOOL_MOVE) && part >= 0) {
        zs_part p;
        if (zs_app_part_get(zg_model_core(v->model), (size_t)part, &p) == ZS_OK) {
            /* GTK can turn a vertical wheel with Shift into dx. */
            double step = dy != 0 ? dy : dx;
            zg_model_part_rotate(v->model, (size_t)part, p.rotation + (step > 0 ? -15 : 15));
        }
        return TRUE;
    }
    /* A two-finger swipe on a touchpad (a scroll in pixels) zooms toward
     * the pointer, as a pinch does (the zoom gesture): 40 pixels are one
     * wheel step. A mouse wheel (steps) zooms toward the pointer too. */
    if (v->view && gtk_event_controller_scroll_get_unit(c) == GDK_SCROLL_UNIT_SURFACE) {
        zs_view_zoom_at(v->view, powf(1.15f, (float)(dy / 40.0)), (float)(v->pointer_x * scale), (float)(v->pointer_y * scale));
        queue_frame(v);
        return TRUE;
    }
    if (v->view) zs_view_zoom_at(v->view, powf(1.15f, (float)dy), (float)(v->pointer_x * scale), (float)(v->pointer_y * scale));
    start_animation(v);
    return TRUE;
}

void zg_view3d_measure_click(GtkWidget *view, double x, double y, gboolean shift) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    double p[3];
    if (!zs_view_surface_point(v->view, (float)(x * scale), (float)(y * scale), !shift, p)) return;
    /* A circle or an arc under the pointer: the point is its center, with
     * its radius, and the line shows selected. Shift: the point itself. */
    size_t seg = 0;
    size_t path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
    zs_measure m;
    if (!shift && path != (size_t)-1 && zs_app_measure(zg_model_core(v->model), path, seg, &m) == ZS_OK && (m.shape == 1 || m.shape == 2)) {
        zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
        zg_model_measure_add_shape(v->model, m.center_x, m.center_y, p[2], m.radius, m.shape);
        return;
    }
    zg_model_measure_add(v->model, p[0], p[1], p[2]);
}

/* The paths of a run that light up with the line, at most. */
#define RUN_MAX 20000

/* Shift+click in the Select tool: the line under x, y (points) and its
 * whole run, from the retraction before it to the next one (one
 * extrusion), lit together (zs_app_path_run). A note gives the count. */
static void pick_run(View3d *v, double x, double y) {
    int scale = gtk_widget_get_scale_factor(v->area);
    size_t seg = 0;
    size_t path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
    zg_support_clear_pick(v->support);
    if (path == (size_t)-1) {
        zg_model_select(v->model, -1);
        return;
    }
    /* A new selection, also of the same line: no lines of an old
     * selection of many. */
    zg_model_select(v->model, (gint64)path);
    zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
    size_t first = 0, last = 0;
    if (zs_app_path_run(zg_model_core(v->model), path, &first, &last) != ZS_OK || last < first) return;
    size_t *others = g_new(size_t, MIN(last - first + 1, RUN_MAX));
    size_t k = 0;
    for (size_t i = first; i <= last && k < RUN_MAX; i++)
        if (i != path) others[k++] = i;
    zs_view_highlight_more(v->view, others, k);
    g_free(others);
    v->run_lit = TRUE;
    queue_frame(v);
    char *text = last > first ? g_strdup_printf("A run of %zu lines: one extrusion, from a retraction to the next.", last - first + 1)
                              : g_strdup("A run of one line: it has a retraction before and after it.");
    GtkWidget *preview = v->area;
    while (preview && !g_object_get_data(G_OBJECT(preview), "zg-preview")) preview = gtk_widget_get_parent(preview);
    if (preview) zg_preview_note(preview, text, 5000);
    if (g_getenv("ZSLICE_SELECT_TEST")) g_message("select test: %s", text);
    g_free(text);
}

static void on_release(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    if (n != 1 || !v->view || fabs(x - v->press_x) > 4 || fabs(y - v->press_y) > 4) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    /* Ctrl+click: select a part (to move, turn, or remove it). A click: a
     * line. Shift+click in the Select tool: the run of the line. In the
     * other tools Shift+click, and Ctrl+Shift+click in the Select tool:
     * add the part under the pointer to the selection of parts, or take
     * it out; with no part there, add the line to the selection of lines,
     * or take it out. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    gboolean shift = (mods & GDK_SHIFT_MASK) != 0, ctrl = (mods & GDK_CONTROL_MASK) != 0;
    gboolean select_tool = zg_model_tool(v->model) == ZG_TOOL_SELECT;
    /* A click elsewhere ends a range of layers, and the run of a
     * Shift+click. */
    zg_range_card_close(zg_range_card_of(v->area));
    if (v->run_lit) {
        v->run_lit = FALSE;
        more_from_model(v);
        queue_frame(v);
    }
    /* The measure tape: a point of the print (the end of a line near the
     * pointer), or of the bed. */
    if (zg_model_tool(v->model) == ZG_TOOL_MEASURE) {
        zg_view3d_measure_click(v->area, x, y, (mods & GDK_SHIFT_MASK) != 0);
        return;
    }
    /* The Support tool: a point of an area, or a click on an outline. */
    if (zg_model_tool(v->model) == ZG_TOOL_SUPPORT && !(mods & GDK_CONTROL_MASK)) {
        zg_support_click(v->support, x, y, (mods & GDK_SHIFT_MASK) != 0, (mods & GDK_ALT_MASK) != 0);
        return;
    }
    if (shift && !ctrl && select_tool) {
        pick_run(v, x, y);
        return;
    }
    gboolean add = shift && (!select_tool || ctrl);
    if (add && zg_model_tool(v->model) != ZG_TOOL_GRAB) {
        gint64 part = part_at(v, x, y, NULL, NULL);
        if (part >= 0) {
            zg_model_toggle_part(v->model, part);
            return;
        }
    }
    if ((ctrl && !(add && select_tool)) || zg_model_tool(v->model) == ZG_TOOL_MOVE || zg_model_tool(v->model) == ZG_TOOL_TURN) {
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
    if (add) {
        if (path != (size_t)-1) zg_model_toggle_more(v->model, (gint64)path);
        return;
    }
    /* The Select tool: a click on a support line selects that support
     * (support-tool.h, zg_support_select_at), and not the line. */
    double sp[3];
    int feature = path != (size_t)-1 ? zs_view_path_feature(v->view, path) : -1;
    if (zg_model_tool(v->model) == ZG_TOOL_SELECT && (feature == ZS_FEATURE_SUPPORT || feature == ZS_FEATURE_SUPPORT_INTERFACE) &&
        path_point(v, (gint64)path, (gint64)seg, &sp[0], &sp[1], &sp[2])) {
        zg_model_select(v->model, -1);
        zg_support_select_at(v->support, sp[0], sp[1], sp[2]);
        return;
    }
    zg_support_clear_pick(v->support);
    if (path == (size_t)-1) zg_model_select(v->model, -1);
    else zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
}

/* ---- the context menu ----
 *
 * A right click on a line selects it (and its segment), and the menu acts
 * at the middle of that segment, on its layer: support of a kind there, no
 * support there, or no marks there. */

/* The middle of segment `seg` of path `path` (-1: the middle of the
 * path), on its layer: x, y, z in mm. */
static gboolean path_point(View3d *v, gint64 path, gint64 seg, double *x, double *y, double *z) {
    zs_toolpaths tp;
    if (path < 0 || zs_app_toolpaths(zg_model_core(v->model), &tp) != ZS_OK || (size_t)path >= tp.path_count) return FALSE;
    uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
    if (b <= a) return FALSE;
    uint32_t i = seg >= 0 && a + (uint32_t)seg + 1 < b ? a + (uint32_t)seg : a + (b - a) / 2 - ((b - a) > 1 ? 1 : 0);
    uint32_t j = i + 1 < b ? i + 1 : i;
    *x = (tp.points[2 * i] + tp.points[2 * j]) / 2;
    *y = (tp.points[2 * i + 1] + tp.points[2 * j + 1]) / 2;
    size_t layer = 0;
    while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
    *z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
    return TRUE;
}

/* The place of the menu: x, y, z in mm, from the selected segment. */
static gboolean mark_place(View3d *v, double *x, double *y, double *z) {
    return path_point(v, zg_model_selected(v->model), zg_model_segment(v->model), x, y, z);
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

/* "Remove this support": the support line under the menu holds up an
 * overhang; a block area over that overhang takes the support away, as the
 * Support tool does. The support marks of the user near the line go too. */
static void on_remove_support(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    zs_app *core = zg_model_core(v->model);
    double x, y, z;
    if (!mark_place(v, &x, &y, &z)) return;
    gboolean changed = zg_model_mark_remove_near(v->model, x, y, z, 3) > 0;
    /* The overhang over the line: up from it, half a millimeter a step,
     * to the first surface that faces down. */
    zs_toolpaths tp;
    double top = zs_app_toolpaths(core, &tp) == ZS_OK && tp.layer_count > 0 ? tp.layer_z[tp.layer_count - 1] : z;
    enum { MAX_PTS = 256 };
    double pts[3 * MAX_PTS], lo = 0, hi = 0;
    size_t n = 0;
    for (double zz = z; zz <= top + 0.5; zz += 0.5) {
        if (zs_app_support_pick(core, x, y, zz, 2, pts, MAX_PTS, &n, &lo, &hi) >= 0 && n >= 3) {
            if (zg_model_support_add(v->model, 3, pts, n, lo, hi) >= 0) changed = TRUE;
            break;
        }
    }
    if (!changed) g_message("zslice: found no overhang over this support");
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

/* Delete branch: the menu of a dot of a support tree that the Select tool
 * picked. */
static void on_delete_branch(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    zg_support_delete_branch(v->support);
}

static void on_reset_view(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (!v->view) return;
    zs_view_reset_smooth(v->view);
    start_animation(v);
}

gboolean zg_view3d_plate_origin(GtkWidget *view, size_t i, double *x, double *y) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && v->view && zs_view_plate_origin(v->view, i, x, y) == ZS_OK;
}

void zg_view3d_frame_all(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    zs_view_frame_plate(v->view, (size_t)-1);
    start_animation(v);
}

void zg_view3d_reset(GtkWidget *view) {
    on_reset_view(NULL, NULL, g_object_get_data(G_OBJECT(view), "zg-view3d"));
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
    /* The menu is for what is under the pointer: no line there (the bed)
     * clears the selection. */
    if (path != (size_t)-1) zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
    else zg_model_select(v->model, -1);
    show_menu(v, x, y);
}

/* For select_hook: "auto" for x is the first line in a scan from the
 * middle of the view, in rings of 10 points. */
static void hook_point(View3d *v, const char *xs, const char *ys, double *x, double *y) {
    *x = g_ascii_strtod(xs, NULL);
    *y = g_ascii_strtod(ys, NULL);
    if (g_strcmp0(xs, "auto") != 0) return;
    int scale = gtk_widget_get_scale_factor(v->area);
    double cx = gtk_widget_get_width(v->area) / 2.0, cy = gtk_widget_get_height(v->area) / 2.0;
    for (int r = 0; r < 300; r += 10)
        for (int dy = -r; dy <= r; dy += 10)
            for (int dx = -r; dx <= r; dx += 10) {
                if (abs(dx) != r && abs(dy) != r) continue;
                if (zs_view_pick(v->view, (float)((cx + dx) * scale), (float)((cy + dy) * scale)) == (size_t)-1) continue;
                *x = cx + dx;
                *y = cy + dy;
                return;
            }
}

/* ZSLICE_SELECT_TEST: "parts" (a copy of part 0, the plate arranged, and
 * both parts selected with Shift), "range lo hi" (a drag over layers lo to
 * hi), "run x y" (a Shift+click of the Select tool at x, y, points),
 * "body x y n" (a click on the line at x, y, then Shift+K n times, or
 * Shift+J for n < 0), or "support x y [style]" (a click of the Select
 * tool at x, y, points; with a style, the support goes on first). For x
 * "auto": the first line from the middle of the view (run, body), or the
 * first support line (support). The log says what the Select tool did. */
static void select_hook(gpointer data) {
    View3d *v = data;
    char **f = g_strsplit(g_getenv("ZSLICE_SELECT_TEST"), " ", 4);
    if (g_strcmp0(f[0], "parts") == 0) {
        zg_model_part_duplicate(v->model, 0);
        zg_model_plate_arrange(v->model);
        zg_model_select_part(v->model, 0);
        zg_model_toggle_part(v->model, 1);
        guint n = 0;
        zg_model_parts(v->model, &n);
        g_message("select test: %u parts selected", n);
    } else if (g_strcmp0(f[0], "range") == 0 && f[1] && f[2]) {
        size_t lo = (size_t)atoi(f[1]), hi = (size_t)atoi(f[2]);
        zs_view_light_layers(v->view, lo, hi);
        GtkWidget *card = zg_range_card_of(v->area);
        if (card) zg_range_card_show(card, lo, hi);
        queue_frame(v);
        g_message("select test: layers %zu to %zu, card %d", lo, hi, card && zg_range_card_open(card));
    } else if (g_strcmp0(f[0], "run") == 0 && f[1] && f[2]) {
        double x, y;
        hook_point(v, f[1], f[2], &x, &y);
        pick_run(v, x, y);
        g_message("select test: line %" G_GINT64_FORMAT ", run lit %d", zg_model_selected(v->model), v->run_lit);
    } else if (g_strcmp0(f[0], "body") == 0 && f[1] && f[2] && f[3]) {
        int scale = gtk_widget_get_scale_factor(v->area);
        double x, y;
        hook_point(v, f[1], f[2], &x, &y);
        size_t seg = 0;
        size_t path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
        if (path != (size_t)-1) zg_model_select_segment(v->model, (gint64)path, (gint64)seg);
        int n = atoi(f[3]);
        for (int i = 0; i < abs(n); i++) zg_view3d_key_range(v->area, n > 0 ? 1 : -1);
        GtkWidget *card = zg_range_card_of(v->area);
        g_message("select test: line %" G_GINT64_FORMAT ", layers %zu to %zu, from line %" G_GINT64_FORMAT ", card %d", zg_model_selected(v->model),
                  v->light_lo, v->light_hi, v->light_path, card && zg_range_card_open(card));
        /* ZSLICE_SELECT_SET=name=value: a change of the layers of the card,
         * and a new slice. The log says how the range lights again. */
        const char *set = g_getenv("ZSLICE_SELECT_SET");
        char **kv = set ? g_strsplit(set, "=", 2) : NULL;
        if (kv && kv[0] && kv[1]) zg_model_set(v->model, kv[0], kv[1], NULL);
        g_strfreev(kv);
    } else if (g_strcmp0(f[0], "support") == 0 && f[1] && f[2]) {
        /* A style ("tree" or "grid"): support on in that style first; the
         * hook runs again after that slice. */
        static gboolean styled;
        if (f[3] && !styled) {
            styled = TRUE;
            zg_model_set(v->model, "project.support_style", f[3], NULL);
            zg_model_set(v->model, "project.support", "everywhere", NULL);
            v->select_hook = FALSE;
            g_strfreev(f);
            return;
        }
        int scale = gtk_widget_get_scale_factor(v->area);
        double x = g_ascii_strtod(f[1], NULL), y = g_ascii_strtod(f[2], NULL), p[3];
        size_t seg = 0, path = (size_t)-1;
        int feature = -1;
        /* "auto": the first support line from the bottom of the view up. */
        if (g_strcmp0(f[1], "auto") == 0) {
            int w = gtk_widget_get_width(v->area), h = gtk_widget_get_height(v->area);
            for (int yy = h - 1; yy > 0 && feature != ZS_FEATURE_SUPPORT; yy -= 3)
                for (int xx = 0; xx < w && feature != ZS_FEATURE_SUPPORT; xx += 3) {
                    path = zs_view_pick_segment(v->view, (float)(xx * scale), (float)(yy * scale), &seg);
                    feature = path != (size_t)-1 ? zs_view_path_feature(v->view, path) : -1;
                    x = xx;
                    y = yy;
                }
        } else {
            path = zs_view_pick_segment(v->view, (float)(x * scale), (float)(y * scale), &seg);
            feature = path != (size_t)-1 ? zs_view_path_feature(v->view, path) : -1;
        }
        g_message("select test: the support line at %.0f, %.0f", x, y);
        gboolean ok = (feature == ZS_FEATURE_SUPPORT || feature == ZS_FEATURE_SUPPORT_INTERFACE) && path_point(v, (gint64)path, (gint64)seg, &p[0], &p[1], &p[2]) &&
                      zg_support_select_at(v->support, p[0], p[1], p[2]);
        g_message("select test: feature %d, support picked %d", feature, ok && zg_support_picked(v->support));
        /* ZSLICE_SELECT_DEL=1: Delete, as the key does. */
        if (ok && g_getenv("ZSLICE_SELECT_DEL")) {
            gboolean used = zg_support_key(v->support, GDK_KEY_Delete);
            g_message("select test: Delete %d, %zu support areas, picked %d", used, zs_app_support_area_count(zg_model_core(v->model)), zg_support_picked(v->support));
        }
    }
    g_strfreev(f);
}

static void menu_hook(gpointer data) {
    char **xy = g_strsplit(g_getenv("ZSLICE_MENU"), ",", 2);
    if (xy[0] && xy[1]) menu_at(data, g_ascii_strtod(xy[0], NULL), g_ascii_strtod(xy[1], NULL));
    g_strfreev(xy);
}

/* The menu from the keyboard (the Menu key, or Shift+F10): for the line
 * that is selected now, in the middle of the view. */
void zg_view3d_context_menu(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return;
    show_menu(v, gtk_widget_get_width(v->area) / 2.0, gtk_widget_get_height(v->area) / 2.0);
}

/* A drop of plastic at the right click, on the layer of the selected
 * line (zs_app_edit_add_dot): for a small gap. */
static void on_add_drop(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    gint64 path = zg_model_selected(v->model);
    zs_app *core = zg_model_core(v->model);
    if (path < 0 || !v->view) return;
    int s = gtk_widget_get_scale_factor(v->area);
    double pt[3];
    if (!zs_view_surface_point(v->view, (float)(v->menu_x * s), (float)(v->menu_y * s), 0, pt)) return;
    ptrdiff_t layer = zs_app_path_layer(core, (size_t)path);
    if (layer < 0) return;
    if (zs_app_edit_add_dot(core, (size_t)layer, pt[0], pt[1], 1.0) == ZS_OK) zg_model_edits_changed(v->model);
}

static void show_menu(View3d *v, double x, double y) {
    v->menu_x = x;
    v->menu_y = y;
    /* The menu fits what is under the pointer (as on the web: the list of
     * web/app/context-menu.js): a support line, a line of a part, or no
     * line (the bed). The items of the view show each time. */
    zs_app *core = zg_model_core(v->model);
    gint64 path = zg_model_selected(v->model);
    gboolean on_support = FALSE;
    zs_toolpaths tp;
    if (path >= 0 && zs_app_toolpaths(core, &tp) == ZS_OK && (size_t)path < tp.path_count)
        on_support = tp.path_features[path] == ZS_FEATURE_SUPPORT || tp.path_features[path] == ZS_FEATURE_SUPPORT_INTERFACE;
    gboolean on_part = path >= 0 && !on_support;
    gboolean marks = zs_app_mark_count(core) > 0;
    GMenu *menu = g_menu_new();
    if (on_support) {
        GMenu *sup = g_menu_new();
        g_menu_append(sup, "Remove this support", "view3d.remove-support");
        if (marks) g_menu_append(sup, "Remove the support marks here", "view3d.remove-marks");
        g_menu_append_section(menu, NULL, G_MENU_MODEL(sup));
        g_object_unref(sup);
    }
    if (path >= 0) {
        GMenu *line = g_menu_new();
        GMenuItem *cut = g_menu_item_new("Preview to this layer", "preview.cut-to-layer");
        g_menu_item_set_attribute(cut, "accel", "s", "c");
        g_menu_append_item(line, cut);
        g_object_unref(cut);
        g_menu_append(line, "Copy for AI", "view3d.copy-for-ai");
        g_menu_append_section(menu, NULL, G_MENU_MODEL(line));
        g_object_unref(line);
    }
    if (on_part) {
        GMenu *kinds = g_menu_new();
        g_menu_append(kinds, "Grid", "view3d.add-support(0)");
        g_menu_append(kinds, "Tree", "view3d.add-support(1)");
        g_menu_append(kinds, "Bridge (a pad)", "view3d.add-support(2)");
        GMenu *here = g_menu_new();
        g_menu_append_submenu(here, "Add support here", G_MENU_MODEL(kinds));
        g_menu_append(here, "Block support here", "view3d.add-support(3)");
        if (marks) g_menu_append(here, "Remove the support marks here", "view3d.remove-marks");
        g_menu_append(here, "Add a drop of plastic here", "view3d.add-drop");
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
    if (path < 0) {
        GMenu *plate = g_menu_new();
        g_menu_append(plate, "Smart placement", "win.smart-place");
        g_menu_append(plate, "Arrange the plate", "win.arrange");
        g_menu_append(plate, "Add models\u2026", "app.open");
        g_menu_append(plate, "Clear the plate", "win.clear-plate");
        g_menu_append(plate, "Remove this plate", "win.remove-plate");
        g_menu_append_section(menu, NULL, G_MENU_MODEL(plate));
        g_object_unref(plate);
    }
    GMenu *general = g_menu_new();
    if (marks) g_menu_append(general, "Clear all support marks", "view3d.clear-marks");
    GtkWidget *preview = v->area;
    while (preview && !g_object_get_data(G_OBJECT(preview), "zg-preview")) preview = gtk_widget_get_parent(preview);
    if (preview && zg_preview_is_cut(preview)) {
        GMenuItem *all = g_menu_item_new("Show all layers", "preview.all-layers");
        g_menu_item_set_attribute(all, "accel", "s", "<Shift>c");
        g_menu_append_item(general, all);
        g_object_unref(all);
    }
    g_menu_append(general, "Test print: the top layer…", "preview.debug-print(1)");
    if (preview && zg_preview_is_cut(preview)) g_menu_append(general, "Test print: the layers shown…", "preview.debug-print(0)");
    g_menu_append(general, "Reset the view", "view3d.reset-view");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(general));
    g_object_unref(general);
    popup_menu(v, menu, x, y);
    g_object_unref(menu);
}

/* Opens `menu` at x, y of the view. */
static void popup_menu(View3d *v, GMenu *menu, double x, double y) {
    GtkWidget *pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
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
    /* The other lines of a multiple selection. A new selection clears the
     * run of a Shift+click. A lit range keeps its lines. */
    v->run_lit = FALSE;
    if (!v->light_on || !zg_range_card_open(zg_range_card_of(v->area))) more_from_model(v);
    queue_frame(v);
}

static void on_segment(ZgModel *model, gint64 seg, gpointer data) {
    View3d *v = data;
    gint64 path = zg_model_selected(model);
    if (!v->view || path < 0) return;
    zs_view_highlight_segment(v->view, (size_t)path, (ptrdiff_t)seg);
    queue_frame(v);
}

/* A double click on a side of a part turns the view to face that side,
 * and zooms to it (zs_view_look_at_side). Elsewhere, the view resets. */
static gboolean look_at_side(View3d *v, double x, double y) {
    if (zs_app_state(zg_model_core(v->model)) == ZS_STATE_EMPTY) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    gint64 part = part_at(v, x, y, NULL, NULL);
    zs_part info;
    double size = 0;
    if (part >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)part, &info) == ZS_OK) size = MAX(info.size_x, MAX(info.size_y, info.size_z));
    if (!zs_view_look_at_side(v->view, (float)(x * s), (float)(y * s), (float)size)) return FALSE;
    /* The first click of the double click picked a line: not wanted. */
    zg_model_select(v->model, -1);
    start_animation(v);
    return TRUE;
}

static void support_frame(gpointer data) {
    queue_frame(data);
}

static void support_focus(gpointer data) {
    View3d *v = data;
    apply_focus(v);
    queue_frame(v);
}

gboolean zg_view3d_support_key(GtkWidget *view, guint key) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && !v->hidden && zg_support_key(v->support, key);
}

GtkWidget *zg_view3d_support_card(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return zg_support_card(v->support);
}

static void on_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    View3d *v = data;
    v->press_x = x;
    v->press_y = y;
    if (n != 2 || !v->view) return;
    if (look_at_side(v, x, y)) return;
    zs_view_reset_smooth(v->view);
    start_animation(v);
}

static void view_free(gpointer data) {
    View3d *v = data;
    g_signal_handlers_disconnect_by_data(v->model, v);
    if (v->idle) g_source_remove(v->idle);
    if (v->retry) g_source_remove(v->retry);
    for (guint i = 0; v->hooks && i < v->hooks->len; i++)
        g_signal_handlers_disconnect_by_data(g_array_index(v->hooks, FrameHook, i).owner, v);
    if (v->hooks) g_array_free(v->hooks, TRUE);
    if (v->group) g_array_free(v->group, TRUE);
    if (v->group_xy) g_array_free(v->group_xy, TRUE);
    zg_support_free(v->support);
    if (v->view) zs_view_free(v->view);
    zg_native_surface_free(v->native);
    g_free(v->error);
    g_object_unref(v->model);
    g_free(v);
}

GtkWidget *zg_view3d_new(ZgModel *model) {
    View3d *v = g_new0(View3d, 1);
    v->model = g_object_ref(model);
    v->tape_end = -1;
    v->turn_axis = -1;
    v->area = gtk_drawing_area_new();
    v->support = zg_support_new(model, v->area, (ZgSupportHost){support_frame, support_focus, v});
    gtk_widget_set_hexpand(v->area, TRUE);
    gtk_widget_set_vexpand(v->area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(v->area), draw_message, v, NULL);
    g_signal_connect(v->area, "map", G_CALLBACK(on_map), v);
    g_signal_connect(v->area, "unmap", G_CALLBACK(on_unmap), v);
    g_signal_connect(v->area, "resize", G_CALLBACK(on_resize), v);
    zg_on_theme_changed(v->area, apply_dark, v);

    const struct { guint button; int mode; } drags[] = {
        {GDK_BUTTON_PRIMARY, DRAG_ORBIT},
        {GDK_BUTTON_MIDDLE, DRAG_PAN},
        /* A right drag (two fingers pressed down on a touchpad) pans; a
         * right click opens the menu (on_drag_end). */
        {GDK_BUTTON_SECONDARY, DRAG_RIGHT},
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
    GtkGesture *pinch = gtk_gesture_zoom_new();
    g_signal_connect(pinch, "begin", G_CALLBACK(on_pinch_begin), v);
    g_signal_connect(pinch, "scale-changed", G_CALLBACK(on_pinch), v);
    gtk_widget_add_controller(v->area, GTK_EVENT_CONTROLLER(pinch));
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), v);
    gtk_widget_add_controller(v->area, scroll);
    /* The context menu: a right drag that ends where it began (see
     * on_drag_end). One gesture for the right button, so the drag and the
     * click do not compete for the press. */
    static const GActionEntry menu_actions[] = {
        {.name = "add-support", .activate = on_add_support, .parameter_type = "i"},
        {.name = "remove-marks", .activate = on_remove_marks},
        {.name = "remove-support", .activate = on_remove_support},
        {.name = "clear-marks", .activate = on_clear_marks},
        {.name = "put-down", .activate = on_put_down},
        {.name = "copy-for-ai", .activate = on_copy_for_ai},
        {.name = "add-drop", .activate = on_add_drop},
        {.name = "new-profile", .activate = on_new_profile, .parameter_type = "i"},
        {.name = "place", .activate = on_place, .parameter_type = "i"},
        {.name = "reset-view", .activate = on_reset_view},
        {.name = "delete-branch", .activate = on_delete_branch},
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
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed), v);
    g_signal_connect(model, "measure-changed", G_CALLBACK(on_measure_changed), v);
    g_signal_connect(model, "segment-changed", G_CALLBACK(on_segment), v);
    g_signal_connect(model, "plate-changed", G_CALLBACK(on_plate_changed), v);
    g_signal_connect(model, "plates-changed", G_CALLBACK(on_plates_sync), v);
    g_signal_connect(model, "focus-changed", G_CALLBACK(on_focus_changed), v);
    g_signal_connect(model, "fall", G_CALLBACK(on_fall), v);
    return v->area;
}
