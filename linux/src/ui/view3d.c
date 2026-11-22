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
 * The gizmo of the transform tool (as web/app/gizmo.js): with the Move
 * tool (M; R and G pick it too) and a selected part, three rings and three
 * arrows go on the part. A drag of a ring turns the part about X (red), Y
 * (green), or Z (blue) of the bed, in steps of 15 degrees (Shift: 1); each
 * step goes to the core at once, and the part slices at the end of the
 * drag. A drag of an arrow moves the part along X or Y, or lifts it (Z):
 * up it floats, down it sinks into the bed. A drag of the part carries it
 * on the bed, with smart guides (zs_part_snap; Shift: no snap). A move is
 * live: the beads move on each frame (zs_view_part_preview), and the
 * slice follows as a draft (see live_push). The release ends the drag:
 * one step of the history, the exact slice, and the physics (a part on an
 * edge, or in the air with support off, falls). The core view draws the
 * rings, the arrows, and the guides, finds the handle under the pointer,
 * and gives the angle or the distance of a drag (zs_view_set_gizmo,
 * zs_view_gizmo_at, zs_view_ring_*, zs_view_arrow_*). The widget draws
 * over the subsurface with cairo: the label of a drag. References: the
 * gizmos of PrusaSlicer and OrcaSlicer (docs/references/prusaslicer.md),
 * and the smart guides (docs/references/papers-and-algorithms.md).
 *
 * The Support tool (support-tool.h) gets the clicks, the drags, and the
 * keys of the view while it is on. The Label tool (label-tool.h) gets
 * them too, and the wheel over its selected label. The Paint tool
 * (paint-tool.h) gets the left button, the moves of the pointer, and the
 * keys. Both share the meshes of the parts (part-mesh.h).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "view3d.h"
#include "preview.h"

#include <stdlib.h>
#include <string.h>

#include <math.h>

#include "bed-model.h"
#include "clipboard.h"
#include "label-tool.h"
#include "native-surface.h"
#include "paint-tool.h"
#include "part-mesh.h"
#include "filaments.h"
#include "line-card.h"
#include "range-card.h"
#include "setting-editor.h"
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
    /* The bed and its grids do not draw (key B). */
    gboolean bed_hidden;
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
    /* A point of the start line (mm), to find it again after a load: a
     * slice can number the lines again (a new filament of a body splits
     * its layers). light_pt: there is one. */
    double light_x, light_y;
    gboolean light_pt;
    /* The color of the lit body: the filament the user gave it
     * (0xRRGGBB), or -1 for the yellow of a selection. */
    gint32 light_rgb;
    /* The body of a line that the Filament row of the line card colors:
     * lit in the color of the filament until the slice comes back. */
    gboolean line_lit;
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
    /* A timeout that looks for the end of the copy of a new scene into
     * the GPU (zs_view_scene_pending), or 0. */
    guint scene_poll;
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
    /* The pointer is over the view (a paste goes to it). */
    gboolean pointer_in;
    gboolean gaps_hook, gap_hook; /* the test hooks ran */
    gboolean dbl_hook, ring_hook, menu_hook, select_hook, clip_hook;
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
    /* The signs of the plates (zg_view3d_set_signs): a copy, for a view
     * that starts later. */
    GBytes *sign_rgba;
    float *sign_rects;
    size_t sign_n;
    guint sign_w, sign_h;
    float sign_scale;
    /* The gizmo of the transform tool is on (the core view draws it). */
    gboolean rings_on;
    /* A drag of a ring: its axis (-1: none), the turn that the drag wants,
     * and the turn sent to the core. */
    int turn_axis;
    double turn_want, turn_sent;
    /* The label of a drag of the gizmo (the angle, or the distance) and
     * the pointer, or an empty label. */
    char drag_label[64];
    double drag_label_x, drag_label_y;
    /* The part of a ring drag, and its pivot at the press. */
    gint64 turn_part;
    double turn_pivot[3];
    /* A live move (an arrow, or a drag of the part; see live_begin): the
     * part, the axis of the arrow (-1: on the bed), the pose (x, y, lift)
     * at the press, that the drag wants, that the core has, and of the
     * slice in the view, and the size of the part. live_gen: the change
     * of the plate of the last pose sent. live_done: the drag ended, and
     * the preview waits for the slice of the last pose. live_hz: the
     * height of the point of the press (the plane of a drag of the part). */
    gboolean live_on, live_done, live_pushing;
    gint64 live_part, live_gen;
    int arrow_axis;
    double live_start[3], live_target[3], live_sent[3], live_shown[3], live_size[3];
    double live_hz;
    /* The poses sent to the core in this drag, with the change of the
     * plate of each (the last 8): a load of change g shows the last pose
     * sent at or before g. */
    gint64 live_hist_gen[8];
    double live_hist[8][3];
    int live_hist_n;
    /* The beads of a fall start at this offset from the body (the end of
     * a live move). */
    double fall_off[3];
    /* The slices wait for the end of a ring drag, so the beads of the
     * view show the part before the turn until the slice of its new place
     * comes. The base is the turn that puts them where the part is now
     * (base_q: a unit quaternion x, y, z, w about base_c, then the move
     * base_m), and press_q, press_c, press_m are the base at the press of
     * the drag (press_on: there was one). */
    gboolean base_on;
    double base_q[4], base_c[3], base_m[3];
    /* The change of the plate (zg_model_edit_gen) that the base and the
     * fall lead to: a slice of it ends them. */
    gint64 base_gen, fall_gen;
    gboolean press_on;
    double press_q[4], press_c[3], press_m[3];
    /* The last frame of a fall (zg_model_fall_step): the view shows it
     * until the slice of the new place. */
    gboolean fall_shown;
    double fall_f[10];
    /* The Support tool, and the cursor that it set last. */
    ZgSupport *support;
    /* The Label tool, the Paint tool, and the meshes of the parts that
     * they share. */
    ZgLabelTool *label;
    ZgPaintTool *paint;
    ZgPartMeshes *meshes;
    const char *cursor;
    /* The fall of a part: a tick on each frame runs the rigid body
     * (zg_model_fall_step). */
    guint fall_tick;
    gint64 fall_part, fall_last;
} View3d;

static void apply_signs(View3d *v);

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

static void load_data(View3d *v);
static void show_preview(View3d *v);

/* The new scene went in after the copy of its beads into the GPU: the
 * selection, the lit layers, and the plates again, and a frame. */
static gboolean poll_scene(gpointer data) {
    View3d *v = data;
    if (v->view && zs_view_scene_pending(v->view)) {
        if (!zs_view_scene_poll(v->view)) return G_SOURCE_CONTINUE;
        v->scene_poll = 0;
        load_data(v);
        return G_SOURCE_REMOVE;
    }
    v->scene_poll = 0;
    return G_SOURCE_REMOVE;
}

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
        zg_label_tool_place(v->label);
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
static void live_loaded(View3d *v);
static void menu_hook(gpointer data);
static void select_hook(gpointer data);
static void clip_hook(gpointer data);
static void label_focus(gpointer data);
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
    /* A large new scene: the view draws the old one until the copy of its
     * beads into the GPU is done (poll_scene). */
    if (zs_view_scene_pending(v->view) && !v->scene_poll) v->scene_poll = g_timeout_add(4, poll_scene, v);
    /* A load ends the preview of a part. The beads of the slice of the
     * part as it is now end the turn and the fall; else the view moves
     * the old beads again. */
    if (zg_model_plate_switching(v->model)) {
        v->base_on = FALSE;
        v->fall_shown = FALSE;
    } else if (!zs_view_scene_pending(v->view)) {
        gint64 shown = zg_model_shown_gen(v->model);
        if (shown >= v->base_gen) v->base_on = FALSE;
        if (shown >= v->fall_gen) v->fall_shown = FALSE;
    }
    live_loaded(v);
    if (v->base_on || v->fall_shown || v->live_on) show_preview(v);
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
    if ((g_getenv("ZSLICE_RING_DRAG") || g_getenv("ZSLICE_ARROW_DRAG")) && !v->ring_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE &&
        zg_model_selected_part(v->model) >= 0) {
        v->ring_hook = TRUE;
        g_timeout_add_once(1000, ring_drag_hook, v);
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
    /* For tests: ZSLICE_CLIP_TEST selects for the keys of the clipboard
     * 1 s after the first slice (see clip_hook). */
    if (g_getenv("ZSLICE_CLIP_TEST") && !v->clip_hook && zs_app_state(zg_model_core(v->model)) == ZS_STATE_DONE) {
        v->clip_hook = TRUE;
        g_timeout_add_once(1000, clip_hook, v);
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
    zg_label_tool_set_shown(v->label, TRUE);
    zg_paint_tool_set_shown(v->paint, TRUE);
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
    zg_label_tool_set_view(v->label, v->view);
    zg_paint_tool_set_view(v->paint, v->view);
    apply_signs(v);
    if (g_getenv("ZSLICE_BENCH")) v->bench = 1;
    apply_dark(v);
    load_data(v);
    sync_geometry(v);
    if (v->has_pending_camera) {
        zs_view_set_camera(v->view, v->pending_camera);
        v->has_pending_camera = FALSE;
    }
    zs_view_set_bed_hidden(v->view, v->bed_hidden);
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
/* Hides the bed and its grids (TRUE), so the bottom of a part shows from
 * below, or shows them again. */
void zg_view3d_set_bed_hidden(GtkWidget *view, gboolean hidden) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v) return;
    v->bed_hidden = hidden;
    if (v->view) {
        zs_view_set_bed_hidden(v->view, hidden);
        gtk_widget_queue_draw(v->area);
    }
}

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
    zg_label_release(v->label);
    zg_label_tool_set_shown(v->label, FALSE);
    zg_paint_release(v->paint);
    zg_paint_tool_set_shown(v->paint, FALSE);
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

/* The core view draws the gizmo. Here: the label of a drag of it (the
 * angle of a turn, or the distance of a move). */
static void draw_rings(View3d *v, cairo_t *cr) {
    if (!v->drag_label[0]) return;
    /* Next to the pointer. */
    PangoLayout *layout = gtk_widget_create_pango_layout(v->area, v->drag_label);
    int tw, th;
    pango_layout_get_pixel_size(layout, &tw, &th);
    double x = v->drag_label_x + 16, y = v->drag_label_y - 30;
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
    return v && (v->anim || v->fall_tick || v->bench == 2);
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

/* ---- the gizmo of the transform tool ---- */

static gint64 part_at(View3d *v, double x, double y, double *bx, double *by);

/* The radius of the rings around a part, mm (as web/app/gizmo.js). */
static double gizmo_radius(const zs_part *p) {
    return 0.62 * MAX(p->size_x, MAX(p->size_y, p->size_z)) + 4;
}

/* The gizmo on the selected part: the core view draws the rings and the
 * arrows, and finds the handle under a pixel (zs_view_set_gizmo,
 * zs_view_gizmo_at). During a drag it goes with the part. */
static void compute_rings(View3d *v) {
    gboolean was = v->rings_on;
    v->rings_on = FALSE;
    gint64 i = zg_model_selected_part(v->model);
    zs_part p;
    if (v->view && zg_model_tool(v->model) == ZG_TOOL_MOVE && i >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) == ZS_OK) {
        double x = p.x, y = p.y, z = p.z;
        if (v->live_on && v->live_part == i) {
            x = v->live_target[0];
            y = v->live_target[1];
            z = v->live_target[2];
        }
        zs_view_set_gizmo(v->view, x, y, MAX(z, 0) + p.size_z / 2, gizmo_radius(&p), 1);
        v->rings_on = TRUE;
    } else if (was && v->view) {
        zs_view_set_gizmo(v->view, 0, 0, 0, 0, 0);
    }
    if (was != v->rings_on) queue_frame(v);
}

/* The handle under the point x, y (within 9 points): a ring (0-2), an
 * arrow (3-5), or -1. */
static int handle_at(View3d *v, double x, double y) {
    compute_rings(v);
    if (!v->rings_on) return -1;
    int s = gtk_widget_get_scale_factor(v->area);
    return zs_view_gizmo_at(v->view, (float)(x * s), (float)(y * s), 9.0f * s);
}

/* One step of a ring drag to the core: the turn since the last step. */
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

static void live_begin(View3d *v, gint64 part, int axis);

/* A press on a handle at x, y: a ring starts a turn, an arrow a move
 * along its axis. FALSE if no handle is there. The slices wait for the
 * end of the drag (a move slices live: see live_push). */
static gboolean ring_press(View3d *v, double x, double y) {
    int a = handle_at(v, x, y);
    if (a < 0) return FALSE;
    int s = gtk_widget_get_scale_factor(v->area);
    gint64 part = zg_model_selected_part(v->model);
    if (a >= 3) {
        if (part < 0 || !zs_view_arrow_press(v->view, a - 3, (float)(x * s), (float)(y * s))) return FALSE;
        live_begin(v, part, a - 3);
        v->drag_label_x = x;
        v->drag_label_y = y;
        return TRUE;
    }
    if (!zs_view_ring_press(v->view, a, (float)(x * s), (float)(y * s))) return FALSE;
    v->turn_axis = a;
    v->turn_want = v->turn_sent = 0;
    v->drag_label_x = x;
    v->drag_label_y = y;
    v->turn_part = part;
    zs_part p;
    if (v->turn_part >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)v->turn_part, &p) == ZS_OK) {
        v->turn_pivot[0] = p.x;
        v->turn_pivot[1] = p.y;
        v->turn_pivot[2] = MAX(p.z, 0) + p.size_z / 2;
    } else {
        v->turn_part = -1;
    }
    v->press_on = v->base_on;
    memcpy(v->press_q, v->base_q, sizeof v->press_q);
    memcpy(v->press_c, v->base_c, sizeof v->press_c);
    memcpy(v->press_m, v->base_m, sizeof v->press_m);
    zg_model_hold(v->model, TRUE);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
    return TRUE;
}

/* The turn q1 about c1 and the move m1 after the turn q0 about c0 and the
 * move m0: as one turn q about c0 and a move m. */
static void turn_compose(const double q1[4], const double c1[3], const double m1[3], const double q0[4], const double c0[3],
                         const double m0[3], double q[4], double m[3]) {
    double t[4] = {
        q1[3] * q0[0] + q1[0] * q0[3] + q1[1] * q0[2] - q1[2] * q0[1],
        q1[3] * q0[1] - q1[0] * q0[2] + q1[1] * q0[3] + q1[2] * q0[0],
        q1[3] * q0[2] + q1[0] * q0[1] - q1[1] * q0[0] + q1[2] * q0[3],
        q1[3] * q0[3] - q1[0] * q0[0] - q1[1] * q0[1] - q1[2] * q0[2],
    };
    /* The point c0 + m0 - c1 turned by q1. */
    double d[3] = {c0[0] + m0[0] - c1[0], c0[1] + m0[1] - c1[1], c0[2] + m0[2] - c1[2]};
    double x = q1[0], y = q1[1], z = q1[2], w = q1[3];
    double r[3] = {
        (1 - 2 * (y * y + z * z)) * d[0] + 2 * (x * y - z * w) * d[1] + 2 * (x * z + y * w) * d[2],
        2 * (x * y + z * w) * d[0] + (1 - 2 * (x * x + z * z)) * d[1] + 2 * (y * z - x * w) * d[2],
        2 * (x * z - y * w) * d[0] + 2 * (y * z + x * w) * d[1] + (1 - 2 * (x * x + y * y)) * d[2],
    };
    for (int k = 0; k < 3; k++) m[k] = r[k] + c1[k] + m1[k] - c0[k];
    for (int k = 0; k < 4; k++) q[k] = t[k];
}

static void live_preview(View3d *v);

/* The part in the view: the beads of the last slice turned by the base
 * (a ring drag, or a turn that waits for its slice), and by the fall on
 * top of it, or moved by a live drag. */
static void show_preview(View3d *v) {
    if (!v->view) return;
    if (v->fall_shown) {
        const double *f = v->fall_f;
        if (!v->base_on || v->fall_part != v->turn_part) {
            /* The beads are at fall_off from the start of the fall (the
             * slice of a live move came before its end): the fall moves
             * them by its turn of that offset too. */
            double m[3] = {f[7], f[8], f[9]};
            const double *o = v->fall_off;
            double x = f[0], y = f[1], z = f[2], w = f[3];
            m[0] += (1 - 2 * (y * y + z * z)) * o[0] + 2 * (x * y - z * w) * o[1] + 2 * (x * z + y * w) * o[2];
            m[1] += 2 * (x * y + z * w) * o[0] + (1 - 2 * (x * x + z * z)) * o[1] + 2 * (y * z - x * w) * o[2];
            m[2] += 2 * (x * z - y * w) * o[0] + 2 * (y * z + x * w) * o[1] + (1 - 2 * (x * x + y * y)) * o[2];
            zs_view_part_preview(v->view, (int)v->fall_part, (float)f[0], (float)f[1], (float)f[2], (float)f[3], (float)f[4], (float)f[5],
                                 (float)f[6], (float)m[0], (float)m[1], (float)m[2], 0);
            return;
        }
        double q[4], m[3];
        turn_compose(f, f + 4, f + 7, v->base_q, v->base_c, v->base_m, q, m);
        zs_view_part_preview(v->view, (int)v->fall_part, (float)q[0], (float)q[1], (float)q[2], (float)q[3], (float)v->base_c[0],
                             (float)v->base_c[1], (float)v->base_c[2], (float)m[0], (float)m[1], (float)m[2], 0);
        return;
    }
    if (v->base_on) {
        zs_view_part_preview(v->view, (int)v->turn_part, (float)v->base_q[0], (float)v->base_q[1], (float)v->base_q[2], (float)v->base_q[3],
                             (float)v->base_c[0], (float)v->base_c[1], (float)v->base_c[2], (float)v->base_m[0], (float)v->base_m[1],
                             (float)v->base_m[2], 0);
        return;
    }
    if (v->live_on) {
        live_preview(v);
        return;
    }
    zs_view_part_preview(v->view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
}

/* The beads of the part turn in the view at once, about the axis of the
 * bed, by the angle of the drag (after the base at the press, if the
 * slice of an earlier turn has not come yet). */
static void turn_preview(View3d *v) {
    if (v->turn_part < 0) return;
    double t = v->turn_want * G_PI / 180 / 2;
    double ax[3] = {0, 0, 0};
    ax[v->turn_axis] = 1;
    double s = sin(t);
    double q1[4] = {ax[0] * s, ax[1] * s, ax[2] * s, cos(t)};
    double zero[3] = {0, 0, 0};
    if (v->press_on) {
        turn_compose(q1, v->turn_pivot, zero, v->press_q, v->press_c, v->press_m, v->base_q, v->base_m);
        memcpy(v->base_c, v->press_c, sizeof v->base_c);
    } else {
        memcpy(v->base_q, q1, sizeof v->base_q);
        memcpy(v->base_c, v->turn_pivot, sizeof v->base_c);
    }
    v->base_on = v->press_on || v->turn_want != 0;
    v->base_gen = zg_model_edit_gen(v->model);
    zs_part p;
    if (!v->base_on || !v->view || zs_app_part_get(zg_model_core(v->model), (size_t)v->turn_part, &p) != ZS_OK) {
        v->base_on = FALSE;
        show_preview(v);
        return;
    }
    /* The view places the turned beads as the core places the part: the
     * center of its box at the center of the footprint, its lowest bead
     * at the lift (on the bed for a part that sinks: the view never draws
     * it under the bed). The base keeps the move that the view found. */
    float m[3];
    zs_view_part_preview(v->view, (int)v->turn_part, (float)v->base_q[0], (float)v->base_q[1], (float)v->base_q[2], (float)v->base_q[3],
                         (float)v->base_c[0], (float)v->base_c[1], (float)v->base_c[2], (float)p.x, (float)p.y, (float)MAX(p.z, 0),
                         ZS_PREVIEW_ON_BED | ZS_PREVIEW_CENTERED);
    if (zs_view_part_preview_move(v->view, m))
        for (int k = 0; k < 3; k++) v->base_m[k] = m[k];
}

/* The pointer of a ring drag is at x, y: the part turns in steps of 15
 * degrees (fine: 1 degree; the core gives the angle, in the sense of the
 * ring on the screen). */
static void ring_move(View3d *v, double x, double y, gboolean fine) {
    if (v->turn_axis < 0) return;
    v->drag_label_x = x;
    v->drag_label_y = y;
    int s = gtk_widget_get_scale_factor(v->area);
    v->turn_want = round(zs_view_ring_drag(v->view, (float)(x * s), (float)(y * s), fine ? 1 : 15));
    g_snprintf(v->drag_label, sizeof v->drag_label, "%s%.0f° about %s", v->turn_want > 0 ? "+" : "", v->turn_want, axis_names[v->turn_axis]);
    turn_send(v);
    turn_preview(v);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

static void live_end(View3d *v);

/* The end of a drag of a ring or an arrow: the part slices once. */
static void ring_release(View3d *v) {
    if (v->live_on && !v->live_done) {
        live_end(v);
        return;
    }
    if (v->turn_axis < 0) return;
    v->turn_axis = -1;
    v->drag_label[0] = '\0';
    if (v->view) zs_view_ring_release(v->view);
    /* The release slices; a part that cannot stand as turned falls
     * (the model's "fall"). */
    zg_model_hold(v->model, FALSE);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

/* ---- a live move: an arrow, or a drag of the part ----
 *
 * The beads of the part move in the view on each frame
 * (zs_view_part_preview, from the place of the slice in the view). The
 * core gets the place when no slice runs, and slices it as a draft
 * (zg_model_slice_now): the slice follows the drag. The release is one
 * step of the history and the exact slice; then the physics (the model's
 * "fall": a part in the air with support off falls to the bed). */

/* Starts a live move of part `part`: along the arrow of `axis`, or on the
 * bed (axis -1). */
static void live_begin(View3d *v, gint64 part, int axis) {
    zs_part p;
    if (zs_app_part_get(zg_model_core(v->model), (size_t)part, &p) != ZS_OK) return;
    v->live_on = TRUE;
    v->live_done = FALSE;
    v->live_part = part;
    v->arrow_axis = axis;
    double pose[3] = {p.x, p.y, p.z};
    memcpy(v->live_start, pose, sizeof pose);
    memcpy(v->live_target, pose, sizeof pose);
    memcpy(v->live_sent, pose, sizeof pose);
    memcpy(v->live_shown, pose, sizeof pose);
    v->live_size[0] = p.size_x;
    v->live_size[1] = p.size_y;
    v->live_size[2] = p.size_z;
    v->live_gen = -1;
    v->live_hist_n = 0;
    v->drag_label[0] = '\0';
    zg_model_hold(v->model, TRUE);
}

/* The beads of the part at the target, from the place of the slice in
 * the view. Down, the part sinks into the bed (the bed hides it). */
static void live_preview(View3d *v) {
    if (!v->view || !v->live_on) return;
    const double *t = v->live_target, *s = v->live_shown;
    zs_view_part_preview(v->view, (int)v->live_part, 0, 0, 0, 1, 0, 0, 0, (float)(t[0] - s[0]), (float)(t[1] - s[1]), (float)(t[2] - s[2]),
                         t[2] < 0 ? ZS_PREVIEW_SINK : 0);
}

/* The target goes to the core when no slice runs, and slices as a draft
 * while the drag goes on. */
static void live_push(View3d *v) {
    if (!v->live_on) return;
    const double *t = v->live_target;
    if (t[0] == v->live_sent[0] && t[1] == v->live_sent[1] && t[2] == v->live_sent[2]) return;
    if (!v->live_done && zs_app_state(zg_model_core(v->model)) == ZS_STATE_SLICING) return;
    size_t i = (size_t)v->live_part;
    /* A change of the plate loads the view again (load_data, then
     * live_loaded): the pose counts as sent before the calls. */
    double was[3];
    memcpy(was, v->live_sent, sizeof was);
    memcpy(v->live_sent, t, sizeof v->live_sent);
    v->live_pushing = TRUE;
    if (t[0] != was[0] || t[1] != was[1]) zg_model_part_move(v->model, i, t[0], t[1]);
    if (t[2] != was[2]) zg_model_part_lift(v->model, i, t[2]);
    v->live_pushing = FALSE;
    v->live_gen = zg_model_edit_gen(v->model);
    int k = v->live_hist_n++ % 8;
    v->live_hist_gen[k] = v->live_gen;
    memcpy(v->live_hist[k], t, sizeof v->live_hist[k]);
    if (!v->live_done) zg_model_slice_now(v->model);
}

/* After a load: the slice of the last place sent is in the view, so the
 * preview moves on from there. The slice of the end of the drag ends it. */
static void live_loaded(View3d *v) {
    if (!v->live_on || v->live_gen < 0 || v->live_pushing) return;
    gint64 shown = zg_model_shown_gen(v->model);
    /* The last pose sent at or before the change that the view shows. */
    gint64 best = -1;
    for (int k = 0; k < MIN(v->live_hist_n, 8); k++) {
        if (v->live_hist_gen[k] <= shown && v->live_hist_gen[k] > best) {
            best = v->live_hist_gen[k];
            memcpy(v->live_shown, v->live_hist[k], sizeof v->live_shown);
        }
    }
    if (shown < v->live_gen) {
        live_push(v);
        return;
    }
    if (v->live_done) {
        v->live_on = FALSE;
        return;
    }
    live_push(v);
}

/* mm on the bed for one point of the screen near the point x, y. */
static double mm_per_point(View3d *v, double x, double y) {
    int s = gtk_widget_get_scale_factor(v->area);
    double ax, ay, bx, by;
    if (!zs_view_bed_point(v->view, (float)(x * s), (float)(y * s), &ax, &ay) ||
        !zs_view_bed_point(v->view, (float)((x + 10) * s), (float)(y * s), &bx, &by))
        return 0.2;
    return MAX(hypot(bx - ax, by - ay) / 10, 0.01);
}

/* mm along `axis` for one point of the screen, at the center of the
 * gizmo of the live part. */
static double mm_per_point_axis(View3d *v, int axis) {
    double c[3] = {v->live_start[0], v->live_start[1], MAX(v->live_start[2], 0) + v->live_size[2] / 2}, d[3];
    memcpy(d, c, sizeof d);
    d[axis] += 10;
    double ax, ay, bx, by;
    if (!zg_view3d_pixel_of(v->area, c[0], c[1], c[2], &ax, &ay) || !zg_view3d_pixel_of(v->area, d[0], d[1], d[2], &bx, &by)) return 0.2;
    double px = hypot(bx - ax, by - ay);
    return px > 0.5 ? 10 / px : 0.2;
}

/* The snap of the part at x, y (zs_part_snap): the move of the snap, and
 * the guides in the view (only those along `axis`, for an arrow; -1:
 * all). */
static void live_snap(View3d *v, double *x, double *y, int axis, double px, double py) {
    double tol = axis >= 0 ? mm_per_point_axis(v, axis) * 8 : mm_per_point(v, px, py) * 8;
    zs_app *core = zg_model_core(v->model);
    size_t n = zs_app_part_count(core);
    double *others = g_new(double, 4 * (n > 0 ? n : 1));
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        zs_part q;
        if ((gint64)i == v->live_part || zs_app_part_get(core, i, &q) != ZS_OK) continue;
        double *b = others + 4 * k++;
        b[0] = q.x - q.size_x / 2;
        b[1] = q.y - q.size_y / 2;
        b[2] = q.x + q.size_x / 2;
        b[3] = q.y + q.size_y / 2;
    }
    char *bx = zg_model_get(v->model, "machine.bed_size_x");
    char *by = zg_model_get(v->model, "machine.bed_size_y");
    double bed_x = g_ascii_strtod(bx, NULL), bed_y = g_ascii_strtod(by, NULL);
    g_free(bx);
    g_free(by);
    double box[4] = {*x - v->live_size[0] / 2, *y - v->live_size[1] / 2, *x + v->live_size[0] / 2, *y + v->live_size[1] / 2};
    double d[2] = {0, 0}, guides[12 * 4];
    size_t ng = zs_part_snap(box, others, k, bed_x > 0 ? bed_x : 220, bed_y > 0 ? bed_y : 220, tol, d, guides, 12);
    g_free(others);
    if (axis != 1) *x += d[0];
    if (axis != 0) *y += d[1];
    double keep[12 * 4];
    size_t nk = 0;
    for (size_t i = 0; i < ng; i++) {
        const double *g = guides + 4 * i;
        gboolean vertical = g[0] == g[2];
        if ((axis == 0 && !vertical) || (axis == 1 && vertical)) continue;
        memcpy(keep + 4 * nk++, g, 4 * sizeof(double));
    }
    zs_view_set_guides(v->view, keep, nk);
}

/* The part goes to the target: the view at once, the core when it can. */
static void live_move(View3d *v) {
    compute_rings(v);
    live_preview(v);
    live_push(v);
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

/* The pointer of an arrow drag is at x, y: the part moves along the axis
 * of the arrow (the arrow of Z lifts it). No snap with `free`. */
static void arrow_move(View3d *v, double x, double y, gboolean free) {
    int s = gtk_widget_get_scale_factor(v->area);
    double d;
    if (!zs_view_arrow_drag(v->view, (float)(x * s), (float)(y * s), &d)) return;
    v->drag_label_x = x;
    v->drag_label_y = y;
    double *t = v->live_target;
    memcpy(t, v->live_start, sizeof v->live_target);
    int a = v->arrow_axis;
    if (a == 2) {
        t[2] = v->live_start[2] + d;
        /* The bed snaps: a lift near 0 is 0. At least 0.5 mm of the part
         * stays over the bed. */
        if (!free && fabs(t[2]) < mm_per_point_axis(v, 2) * 8) t[2] = 0;
        t[2] = round(MAX(t[2], -(v->live_size[2] - 0.5)) * 100) / 100;
        if (t[2] == 0) g_snprintf(v->drag_label, sizeof v->drag_label, "On the bed");
        else if (t[2] > 0) g_snprintf(v->drag_label, sizeof v->drag_label, "Lift %.2f mm", t[2]);
        else g_snprintf(v->drag_label, sizeof v->drag_label, "%.2f mm into the bed", -t[2]);
    } else {
        t[a] = v->live_start[a] + d;
        if (!free) live_snap(v, &t[0], &t[1], a, x, y);
        else zs_view_set_guides(v->view, NULL, 0);
        t[a] = round(t[a] * 100) / 100;
        double dd = t[a] - v->live_start[a];
        g_snprintf(v->drag_label, sizeof v->drag_label, "%s%.2f mm along %s", dd >= 0 ? "+" : "", dd, axis_names[a]);
    }
    live_move(v);
}

/* The drag of the part on the bed: the point of the press stays under the
 * pointer, on the level plane of that point. The snap unless `free`. */
static void body_move(View3d *v, double x, double y, gboolean free) {
    int s = gtk_widget_get_scale_factor(v->area);
    double bx, by;
    if (!zs_view_plane_point(v->view, (float)(x * s), (float)(y * s), v->live_hz, &bx, &by)) return;
    double *t = v->live_target;
    t[0] = v->live_start[0] + bx - v->bed_x0;
    t[1] = v->live_start[1] + by - v->bed_y0;
    t[2] = v->live_start[2];
    if (!free) live_snap(v, &t[0], &t[1], -1, x, y);
    else zs_view_set_guides(v->view, NULL, 0);
    t[0] = round(t[0] * 100) / 100;
    t[1] = round(t[1] * 100) / 100;
    live_move(v);
}

/* The end of a live move: the last place, one step of the history, the
 * exact slice, and the physics. The preview stays until the slice of the
 * last place is in the view. */
static void live_end(View3d *v) {
    if (!v->live_on || v->live_done) return;
    v->live_done = TRUE;
    v->arrow_axis = -1;
    v->drag_label[0] = '\0';
    if (v->view) {
        zs_view_ring_release(v->view);
        zs_view_set_guides(v->view, NULL, 0);
    }
    const double *t = v->live_target;
    gboolean moved = t[0] != v->live_start[0] || t[1] != v->live_start[1] || t[2] != v->live_start[2];
    live_push(v);
    zg_model_hold(v->model, FALSE);
    if (!moved) {
        v->live_on = FALSE;
        show_preview(v);
    }
    queue_frame(v);
    gtk_widget_queue_draw(v->area);
}

/* For tests: ZSLICE_RING_DRAG=x0,y0,x1,y1 drags from x0, y0 to x1, y1 in
 * 12 steps (one each 50 ms), with the transform tool. "auto" drags from
 * the point of the rings at +X to the point at +Y; "auto:45" stops the
 * drag at 45 degrees. ZSLICE_RING_DRAG_MS=400 sets the time of a step, for
 * screenshots during the drag. ZSLICE_ARROW_DRAG=axis,mm drags the arrow
 * of the axis (0 X, 1 Y, 2 Z) from its middle to mm further along it, in
 * the same steps; the log gives the pose of the part 3 s later. */
static guint ring_drag_ms(void) {
    const char *ms = g_getenv("ZSLICE_RING_DRAG_MS");
    return ms && atoi(ms) > 0 ? (guint)atoi(ms) : 50;
}

typedef struct {
    View3d *v;
    double x0, y0, x1, y1;
    int step;
    /* The end of the drag at this angle (degrees), or 0. */
    double stop;
    /* An arrow drag: its axis, else -1. */
    int arrow;
} RingDrag;

static void arrow_log(gpointer data) {
    View3d *v = data;
    zs_part p;
    gint64 i = zg_model_selected_part(v->model);
    if (i >= 0 && zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) == ZS_OK)
        g_message("arrow drag: part %" G_GINT64_FORMAT " at %.2f, %.2f, lift %.2f, %s", i, p.x, p.y, p.z, zg_model_falling(v->model) ? "falling" : "at rest");
}

static gboolean ring_drag_step(gpointer data) {
    RingDrag *d = data;
    View3d *v = d->v;
    if (d->step == 0 && !ring_press(v, d->x0, d->y0)) {
        g_message("gizmo drag: no handle at %.0f, %.0f", d->x0, d->y0);
        g_free(d);
        return G_SOURCE_REMOVE;
    }
    d->step++;
    double t = d->step / 12.0;
    double x = d->x0 + (d->x1 - d->x0) * t, y = d->y0 + (d->y1 - d->y0) * t;
    if (d->arrow >= 0) arrow_move(v, x, y, FALSE);
    else ring_move(v, x, y, FALSE);
    if (d->step < 12 && (d->stop <= 0 || fabs(v->turn_want) < d->stop)) return G_SOURCE_CONTINUE;
    if (d->arrow >= 0) {
        g_message("arrow drag: axis %d, target %.2f, %.2f, %.2f", d->arrow, v->live_target[0], v->live_target[1], v->live_target[2]);
        g_timeout_add_once(3000, arrow_log, v);
    } else {
        g_message("ring drag: axis %d, %.0f degrees", v->turn_axis, v->turn_want);
    }
    /* The end of the drag: the label goes, and the part slices. */
    ring_release(v);
    g_free(d);
    return G_SOURCE_REMOVE;
}

static void ring_drag_hook(gpointer data) {
    View3d *v = data;
    gint64 i = zg_model_selected_part(v->model);
    zs_part p;
    if (i < 0 || zs_app_part_get(zg_model_core(v->model), (size_t)i, &p) != ZS_OK) return;
    double r = gizmo_radius(&p);
    double c[3] = {p.x, p.y, MAX(p.z, 0) + p.size_z / 2};
    zg_model_set_tool(v->model, ZG_TOOL_MOVE);
    compute_rings(v);
    const char *arrow = g_getenv("ZSLICE_ARROW_DRAG");
    if (arrow) {
        char **f = g_strsplit(arrow, ",", 2);
        if (f[0] && f[1]) {
            RingDrag *d = g_new0(RingDrag, 1);
            d->v = v;
            d->arrow = CLAMP(atoi(f[0]), 0, 2);
            double a[3], b[3];
            memcpy(a, c, sizeof a);
            a[d->arrow] += r * 1.28;
            memcpy(b, a, sizeof b);
            b[d->arrow] += g_ascii_strtod(f[1], NULL);
            if (zg_view3d_pixel_of(v->area, a[0], a[1], a[2], &d->x0, &d->y0) && zg_view3d_pixel_of(v->area, b[0], b[1], b[2], &d->x1, &d->y1))
                g_timeout_add(ring_drag_ms(), ring_drag_step, d);
            else
                g_free(d);
        }
        g_strfreev(f);
        return;
    }
    /* "auto": from the point of the rings at +X to the point at +Y. */
    const char *spec = g_getenv("ZSLICE_RING_DRAG");
    if (!spec) return;
    if (g_str_has_prefix(spec, "auto")) {
        RingDrag *d = g_new0(RingDrag, 1);
        d->v = v;
        d->arrow = -1;
        if (spec[4] == ':') d->stop = g_ascii_strtod(spec + 5, NULL);
        if (!zg_view3d_pixel_of(v->area, p.x + r, p.y, c[2], &d->x0, &d->y0) || !zg_view3d_pixel_of(v->area, p.x, p.y + r, c[2], &d->x1, &d->y1)) {
            g_free(d);
            return;
        }
        g_timeout_add(ring_drag_ms(), ring_drag_step, d);
        return;
    }
    char **f = g_strsplit(spec, ",", 4);
    if (g_strv_length(f) == 4) {
        RingDrag *d = g_new0(RingDrag, 1);
        d->v = v;
        d->arrow = -1;
        d->x0 = g_ascii_strtod(f[0], NULL);
        d->y0 = g_ascii_strtod(f[1], NULL);
        d->x1 = g_ascii_strtod(f[2], NULL);
        d->y1 = g_ascii_strtod(f[3], NULL);
        g_timeout_add(ring_drag_ms(), ring_drag_step, d);
    }
    g_strfreev(f);
}

/* The mouse, as in Cura: a right drag orbits (turn and tilt, the bed
 * stays level), as a left drag does; a middle drag, or Shift and a drag,
 * pans; and the scroll wheel zooms toward the pointer. On a touchpad: two
 * fingers clicked down and slid pan (a right drag after a touchpad
 * scroll), and a light two-finger swipe or a pinch zooms. */
enum { DRAG_ORBIT, DRAG_PAN, DRAG_RIGHT };

/* ---- the fall of a part ---- */

static gboolean on_fall_tick(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    View3d *v = data;
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    double dt = v->fall_last ? (now - v->fall_last) / 1e6 : 1.0 / 60;
    v->fall_last = now;
    /* For screenshots of a fall: ZSLICE_FALL_SLOW=8 runs it 8 times
     * slower. */
    const char *slow = g_getenv("ZSLICE_FALL_SLOW");
    if (slow && atof(slow) > 1) dt /= atof(slow);
    double f[10];
    /* At rest, the model slices the new place, and the view loads again
     * in the step: the turn and the last frame stay until that slice
     * comes. */
    v->fall_gen = G_MAXINT64;
    int rc = zg_model_fall_step(v->model, MIN(dt, 0.05), f);
    if (rc == 1) {
        memcpy(v->fall_f, f, sizeof v->fall_f);
        v->fall_shown = TRUE;
    } else if (rc == 0) {
        v->fall_gen = zg_model_edit_gen(v->model);
    } else {
        v->fall_shown = FALSE;
    }
    show_preview(v);
    queue_frame(v);
    if (rc == 1) return G_SOURCE_CONTINUE;
    v->fall_tick = 0;
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
    double f[10];
    for (int k = 0; k < 6000 && zg_model_fall_step(v->model, 1.0 / 60, f) == 1; k++) {}
    if (zg_model_falling(v->model)) zg_model_fall_cancel(v->model);
    v->fall_shown = FALSE;
}

/* A part that lost what held it (the model's "fall"): a part turned onto
 * an edge, or a part in the air with support off. A live move first ends
 * its own preview: the fall moves the beads from the place of the part. */
static void on_fall(ZgModel *model, gint64 part, gpointer data) {
    View3d *v = data;
    if (!zg_model_fall_start(model, (size_t)part)) return;
    memset(v->fall_off, 0, sizeof v->fall_off);
    if (v->live_on && v->live_part == part) {
        for (int k = 0; k < 3; k++) v->fall_off[k] = v->live_target[k] - v->live_shown[k];
        v->live_on = FALSE;
    }
    if (v->view && !v->hidden) fall_run(v, part);
    else fall_finish(v);
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

/* The cursor of the tool: a cross for the measure tape, the Support
 * tool, the Label tool, and the Paint tool. */
static void set_cursor(View3d *v, const char *name) {
    if (v->cursor == name) return;
    v->cursor = name;
    gtk_widget_set_cursor_from_name(v->area, name);
}

static void tool_cursor(View3d *v) {
    ZgTool t = zg_model_tool(v->model);
    set_cursor(v, t == ZG_TOOL_MEASURE || t == ZG_TOOL_SUPPORT || t == ZG_TOOL_LABEL || t == ZG_TOOL_PAINT ? "crosshair" : NULL);
}

static void on_tool_changed(ZgModel *model, gpointer data) {
    View3d *v = data;
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

static gboolean path_point(View3d *v, gint64 path, gint64 seg, double *x, double *y, double *z);

/* Lights layers lo to hi: from line `path`, its body of its part on them
 * (zs_view_light_connected); with no line (-1), all their lines. */
static void light_range(View3d *v, gint64 path, size_t lo, size_t hi) {
    zs_view_light_layers(v->view, 1, 0);
    v->run_lit = FALSE;
    v->light_on = TRUE;
    double z;
    v->light_pt = path >= 0 && path_point(v, path, -1, &v->light_x, &v->light_y, &z);
    v->light_rgb = -1;
    zs_view_light_color(v->view, -1);
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
    /* The slice of a filament of the line card: its lines have the color
     * now. */
    if (v->line_lit && !v->light_on) {
        v->line_lit = FALSE;
        zs_view_light_color(v->view, -1);
        zs_view_light_connected(v->view, (size_t)-1, 0, 0, NULL);
        more_from_model(v);
    }
    if (!v->light_on || !zg_range_card_open(zg_range_card_of(v->area))) return;
    gint64 path = v->light_path;
    if (path >= 0 && v->light_pt && v->light_layer >= 0) {
        size_t seg = 0;
        size_t p = zs_view_pick_layer(v->view, (size_t)v->light_layer, v->light_x, v->light_y, &seg);
        if (p != (size_t)-1) path = v->light_path = (gint64)p;
    }
    zs_view_light_color(v->view, v->light_rgb);
    /* No lit layers from a load before, under the lit body. */
    zs_view_light_layers(v->view, 1, 0);
    if (path >= 0 && zs_app_path_layer(zg_model_core(v->model), (size_t)path) != v->light_layer) path = -1;
    if (path < 0 || zs_view_light_connected(v->view, (size_t)path, v->light_lo, v->light_hi, NULL) != ZS_OK)
        zs_view_light_layers(v->view, v->light_lo, v->light_hi);
    if (g_getenv("ZSLICE_SELECT_TEST"))
        g_message("select test: lit again after a load, %s (line %" G_GINT64_FORMAT ", layer %td, color %d)", path >= 0 ? "the body" : "the layers",
                  v->light_path, v->light_layer, v->light_rgb);
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
    v->light_rgb = -1;
    zs_view_light_color(v->view, -1);
    zs_view_light_layers(v->view, 1, 0);
    more_from_model(v);
    queue_frame(v);
}

gboolean zg_view3d_body_lit(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && v->view && v->light_on && v->light_path >= 0;
}

gboolean zg_view3d_paint_body(GtkWidget *view, int filament) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view || !v->light_on || v->light_path < 0 || filament < 1) return FALSE;
    const float *beads = NULL;
    size_t n = 0;
    if (zs_view_connected_beads(v->view, (size_t)v->light_path, v->light_lo, v->light_hi, &beads, &n) != ZS_OK || n == 0) return FALSE;
    /* The body in the color of the filament at once; the slice follows. */
    v->light_rgb = (gint32)zg_filament_rgb24(v->model, filament);
    zs_view_light_color(v->view, v->light_rgb);
    queue_frame(v);
    return zg_model_paint_body(v->model, beads, n, (guint)filament);
}

/* A copy of the beads of the body of `path` on layers lo to hi, or NULL. */
static float *body_copy(View3d *v, gint64 path, size_t lo, size_t hi, size_t *n) {
    const float *beads = NULL;
    *n = 0;
    if (path < 0 || zs_view_connected_beads(v->view, (size_t)path, lo, hi, &beads, n) != ZS_OK || *n == 0) return NULL;
    return g_memdup2(beads, *n * sizeof(float));
}

/* Lights the body of `path` on layers lo to hi in the color of the
 * filament, until the slice comes back (relight). */
static void light_line(View3d *v, gint64 path, size_t lo, size_t hi, int filament) {
    if (v->light_on) return;
    v->line_lit = TRUE;
    zs_view_light_color(v->view, (int32_t)zg_filament_rgb24(v->model, filament));
    zs_view_light_connected(v->view, (size_t)path, lo, hi, NULL);
    queue_frame(v);
}

gboolean zg_view3d_paint_line(GtkWidget *view, gint64 path, int filament, ZgLineBody *out) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    memset(out, 0, sizeof *out);
    if (!v || !v->view || path < 0 || filament < 1) return FALSE;
    ptrdiff_t layer = zs_app_path_layer(zg_model_core(v->model), (size_t)path);
    if (layer < 0) return FALSE;
    size_t n = 0;
    float *beads = body_copy(v, path, (size_t)layer, (size_t)layer, &n);
    if (!beads) return FALSE;
    size_t lo = (size_t)layer, hi = (size_t)layer;
    zs_view_connected_layers(v->view, (size_t)path, &lo, &hi);
    out->layer = (size_t)layer;
    out->lo = lo;
    out->hi = hi;
    /* The beads above and below now: the slice numbers the lines again. */
    if (hi > (size_t)layer) out->above = body_copy(v, path, (size_t)layer + 1, hi, &out->n_above);
    if (lo < (size_t)layer) out->below = body_copy(v, path, lo, (size_t)layer - 1, &out->n_below);
    light_line(v, path, (size_t)layer, (size_t)layer, filament);
    gboolean ok = zg_model_paint_body(v->model, beads, n, (guint)filament);
    g_free(beads);
    return ok;
}

gboolean zg_view3d_paint_beads(GtkWidget *view, const float *beads, size_t n, int filament) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view || !beads || n == 0 || filament < 1) return FALSE;
    gint64 sel = zg_model_selected(v->model);
    if (sel >= 0) {
        size_t lo = (size_t)-1, hi = 0;
        for (size_t k = 1; k < n; k += 9) {
            lo = MIN(lo, (size_t)beads[k]);
            hi = MAX(hi, (size_t)beads[k]);
        }
        ptrdiff_t layer = zs_app_path_layer(zg_model_core(v->model), (size_t)sel);
        if (layer >= 0) light_line(v, sel, MIN(lo, (size_t)layer), MAX(hi, (size_t)layer), filament);
    }
    return zg_model_paint_body(v->model, beads, n, (guint)filament);
}

void zg_line_body_free(ZgLineBody *b) {
    g_clear_pointer(&b->above, g_free);
    g_clear_pointer(&b->below, g_free);
    b->n_above = b->n_below = 0;
}

guint32 zg_view3d_region_find(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view || !v->light_on || v->light_path < 0) return 0;
    const float *beads = NULL;
    size_t n = 0;
    if (zs_view_connected_beads(v->view, (size_t)v->light_path, v->light_lo, v->light_hi, &beads, &n) != ZS_OK || n == 0) return 0;
    uint32_t id = 0;
    zs_app_region_find(zg_model_core(v->model), beads, n, &id);
    return id;
}

gboolean zg_view3d_region_set(GtkWidget *view, guint32 *id, const char *name, const char *value) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return FALSE;
    const float *beads = NULL;
    size_t n = 0;
    if (v->light_on && v->light_path >= 0) zs_view_connected_beads(v->view, (size_t)v->light_path, v->light_lo, v->light_hi, &beads, &n);
    if (n == 0 && (!id || *id == 0)) return FALSE;
    return zg_model_region_set(v->model, beads, n, id, name, value);
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
    /* The light first: the card shows the row of a lit body. */
    light_range(v, v->key_path, lo, hi);
    zg_range_card_show(card, lo, hi);
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
    /* The transform tool: a drag of a ring turns the part, a drag of an
     * arrow moves it along the arrow (Z: lifts it). */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_MOVE && !zg_model_falling(v->model) && ring_press(v, x, y)) {
        set_cursor(v, v->live_on ? "move" : "grabbing");
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
    /* The Support tool: a press on a point of an area drags it. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_SUPPORT && zg_support_press(v->support, x, y)) {
        set_cursor(v, "grabbing");
        return;
    }
    /* The Paint tool: a press paints (Ctrl and a press still move a
     * part). */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_PAINT) {
        GdkModifierType pm = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        if (!(pm & GDK_CONTROL_MASK) && zg_paint_press(v->paint, x, y, (pm & GDK_SHIFT_MASK) != 0)) return;
    }
    /* The Label tool: a press on a label drags it. */
    if (v->view && mode0 == DRAG_ORBIT && zg_model_tool(v->model) == ZG_TOOL_LABEL && zg_label_press(v->label, x, y)) {
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
                /* One part: a live move, with the snap (live_begin). The
                 * point of the press stays under the pointer, on its
                 * level plane. */
                int s = gtk_widget_get_scale_factor(v->area);
                double sp[3];
                v->live_hz = zs_view_surface_point(v->view, (float)(x * s), (float)(y * s), 0, sp) ? MAX(sp[2], 0) : 0;
                if (!zs_view_plane_point(v->view, (float)(x * s), (float)(y * s), v->live_hz, &bx, &by)) v->live_hz = 0;
                if (!zg_model_falling(v->model)) live_begin(v, part, -1);
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
    ring_release(v);
    zg_support_release(v->support);
    zg_label_release(v->label);
    if (GPOINTER_TO_INT(g_object_get_data(G_OBJECT(g), "zg-drag")) == DRAG_ORBIT) zg_paint_release(v->paint);
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
    if (v->turn_axis >= 0 || (v->live_on && !v->live_done)) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        gboolean shift = (mods & GDK_SHIFT_MASK) != 0;
        if (v->turn_axis >= 0) ring_move(v, sx + dx, sy + dy, shift);
        else if (v->arrow_axis >= 0) arrow_move(v, sx + dx, sy + dy, shift);
        else body_move(v, sx + dx, sy + dy, shift);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (v->range_on) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        if (v->range_lit || fabs(dx) > 4 || fabs(dy) > 4) range_move(v, sx + dx, sy + dy);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (mode == DRAG_ORBIT && zg_paint_pressed(v->paint)) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        zg_paint_drag(v->paint, sx + dx, sy + dy);
        v->drag_x = dx;
        v->drag_y = dy;
        return;
    }
    if (zg_label_dragging(v->label)) {
        double sx, sy;
        gtk_gesture_drag_get_start_point(g, &sx, &sy);
        GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
        zg_label_drag(v->label, sx + dx, sy + dy, (mods & GDK_SHIFT_MASK) != 0, (mods & GDK_ALT_MASK) != 0);
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

static void on_leave(GtkEventControllerMotion *c, gpointer data) {
    View3d *v = data;
    v->pointer_in = FALSE;
}

static void on_motion(GtkEventControllerMotion *c, double x, double y, gpointer data) {
    View3d *v = data;
    v->pointer_x = x;
    v->pointer_y = y;
    v->pointer_in = TRUE;
    /* The Support tool: a hand over a point of an area. */
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(c));
    gboolean pressed = (mods & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)) != 0;
    /* The transform tool: a hand over a ring, a cross of arrows over an
     * arrow. */
    if (zg_model_tool(v->model) == ZG_TOOL_MOVE && v->view && !pressed) {
        int h = handle_at(v, x, y);
        set_cursor(v, h >= 3 ? "move" : h >= 0 ? "grab" : NULL);
    }
    if (zg_model_tool(v->model) == ZG_TOOL_SUPPORT && v->view && !pressed) {
        set_cursor(v, zg_support_cursor(v->support, x, y));
        zg_support_hover(v->support, x, y);
    } else if (zg_model_tool(v->model) == ZG_TOOL_LABEL && v->view && !pressed) {
        set_cursor(v, zg_label_cursor(v->label, x, y));
    } else if (zg_model_tool(v->model) == ZG_TOOL_PAINT && v->view && !pressed) {
        zg_paint_hover(v->paint, x, y);
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
    /* The Label tool: the wheel over the selected label turns it. */
    if (zg_model_tool(v->model) == ZG_TOOL_LABEL && !(mods & GDK_CONTROL_MASK) &&
        zg_label_wheel(v->label, v->pointer_x, v->pointer_y, dy != 0 ? dy : dx, (mods & GDK_SHIFT_MASK) != 0))
        return TRUE;
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
    /* A click on the sign of a plate makes that plate active. A sign
     * never covers a part: it gets only the clicks on itself. */
    gint64 sign = zs_view_sign_at(v->view, (float)(x * scale), (float)(y * scale));
    if (sign >= 0) {
        zg_model_plate_select(v->model, (size_t)sign);
        return;
    }
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
    /* The Label tool: a label, or a new label on the face there. */
    if (zg_model_tool(v->model) == ZG_TOOL_LABEL && !(mods & GDK_CONTROL_MASK)) {
        zg_label_click(v->label, x, y);
        return;
    }
    /* The Paint tool: the press painted. */
    if (zg_model_tool(v->model) == ZG_TOOL_PAINT && !(mods & GDK_CONTROL_MASK)) return;
    if (shift && !ctrl && select_tool) {
        pick_run(v, x, y);
        return;
    }
    gboolean add = shift && (!select_tool || ctrl);
    if (add) {
        gint64 part = part_at(v, x, y, NULL, NULL);
        if (part >= 0) {
            zg_model_toggle_part(v->model, part);
            return;
        }
    }
    if ((ctrl && !(add && select_tool)) || zg_model_tool(v->model) == ZG_TOOL_MOVE) {
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

static void apply_signs(View3d *v) {
    if (!v->view) return;
    if (!v->sign_rgba || v->sign_n == 0) {
        zs_view_set_signs(v->view, 0, NULL, 0, 0, NULL, 1);
        return;
    }
    int rc = zs_view_set_signs(v->view, v->sign_n, v->sign_rects, v->sign_w, v->sign_h, g_bytes_get_data(v->sign_rgba, NULL), v->sign_scale);
    if (rc != ZS_OK) g_warning("zslice: the signs of the plates did not load: %s", zg_status_text(rc));
}

gint64 zg_view3d_plate_at(GtkWidget *view, double x, double y) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v || !v->view) return -1;
    int s = gtk_widget_get_scale_factor(v->area);
    return zs_view_plate_at(v->view, (float)(x * s), (float)(y * s));
}

void zg_view3d_set_signs(GtkWidget *view, size_t n, const float *rects, guint width, guint height, GBytes *rgba, float scale) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (!v) return;
    if (v->sign_rgba) g_bytes_unref(v->sign_rgba);
    g_free(v->sign_rects);
    v->sign_rgba = n > 0 && rgba ? g_bytes_ref(rgba) : NULL;
    v->sign_rects = n > 0 ? g_memdup2(rects, n * 4 * sizeof(float)) : NULL;
    v->sign_n = v->sign_rgba ? n : 0;
    v->sign_w = width;
    v->sign_h = height;
    v->sign_scale = scale;
    apply_signs(v);
    queue_frame(v);
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
/* ZSLICE_CLIP_TEST: "parts" selects part 0; "label" puts a label on
 * part 0 and selects it in the Label tool; "range" opens the range card
 * of layers 5 to 10 with a change of the wall count. The view gets the
 * focus, so the keys of a test go to it. */
static void clip_hook(gpointer data) {
    View3d *v = data;
    const char *mode = g_getenv("ZSLICE_CLIP_TEST");
    zs_app *core = zg_model_core(v->model);
    if (zs_app_part_count(core) == 0) return;
    if (strcmp(mode, "label") == 0) {
        zs_part p;
        zs_app_part_get(core, 0, &p);
        char *json = g_strdup_printf("{\"origin\":[%g,%g,10],\"normal\":[0,-1,0],\"right\":[1,0,0],\"filament\":2,\"items\":[{\"kind\":\"text\",\"text\":\"AB\",\"size\":5}]}", p.x, p.y - p.size_y / 2);
        gint64 id = zg_model_label_add(v->model, 0, json);
        g_free(json);
        if (id >= 0) zg_label_tool_open(v->label, 0, (guint32)id);
    } else if (strcmp(mode, "range") == 0) {
        GtkWidget *card = zg_range_card_of(v->area);
        zg_range_card_show(card, 5, 10);
        zg_model_set_for(v->model, "project.wall_count", "4", TRUE, NULL);
    } else {
        zg_model_select_part(v->model, 0);
    }
    label_focus(v);
    g_message("clip test: %s ready", mode);
}

static void close_card_hook(gpointer data) {
    View3d *v = data;
    zg_range_card_close(zg_range_card_of(v->area));
    g_message("select test: the card closed");
}

/* ZSLICE_SELECT_LINE (see select_hook): the filament of the body of the
 * selected line, from the Filament row of its card. */
static void line_hook(gpointer data) {
    View3d *v = data;
    /* After the slice that runs (a draft, then the exact slice). */
    if (zs_app_state(zg_model_core(v->model)) != ZS_STATE_DONE) {
        g_timeout_add_once(1000, line_hook, v);
        return;
    }
    int fil = atoi(g_getenv("ZSLICE_SELECT_LINE"));
    /* A new filament slices again first. */
    if ((int)zs_app_filament_count(zg_model_core(v->model)) < fil && zg_model_filament_add(v->model) >= 0) {
        g_timeout_add_once(1000, line_hook, v);
        return;
    }
    gint64 path = zg_model_selected(v->model);
    ptrdiff_t layer = path >= 0 ? zs_app_path_layer(zg_model_core(v->model), (size_t)path) : -1;
    zg_line_card_pick_filament(zg_line_card_of(v->area), fil);
    g_message("select test: line %" G_GINT64_FORMAT ", layer %td, filament %d", path, layer, fil);
}

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
        /* ZSLICE_SELECT_LINE=n: a click on the line (its card opens), and
         * when the slice is done, filament n for its body on its layer, as
         * a chip of the Filament row of the card. */
        if (g_getenv("ZSLICE_SELECT_LINE") && path != (size_t)-1) {
            zg_model_select(v->model, (gint64)path);
            g_timeout_add_once(5000, line_hook, v);
        }
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
        /* ZSLICE_SELECT_BODY=n: the lit body gets filament n (a second
         * filament first, if the plate has one), as a chip of "This body"
         * on the card. */
        const char *bf = g_getenv("ZSLICE_SELECT_BODY");
        if (bf) {
            int fil = atoi(bf);
            while ((int)zs_app_filament_count(zg_model_core(v->model)) < fil && zg_model_filament_add(v->model) >= 0) {}
            gboolean painted = zg_view3d_paint_body(v->area, fil);
            g_message("select test: body filament %d, painted %d, body lit %d", fil, painted, zg_view3d_body_lit(v->area));
            /* ZSLICE_SELECT_CLOSE=s: the card closes s seconds later, so
             * the body shows in its new filament with no light. */
            const char *cs = g_getenv("ZSLICE_SELECT_CLOSE");
            if (cs) g_timeout_add_once((guint)(1000 * atoi(cs)), close_card_hook, v);
        }
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

/* ---- copy and paste (clipboard.h, as web/app/clipboard.js) ---- */

static void note(View3d *v, const char *text) {
    GtkWidget *preview = v->area;
    while (preview && !g_object_get_data(G_OBJECT(preview), "zg-preview")) preview = gtk_widget_get_parent(preview);
    if (preview) zg_preview_note(preview, text, 4000);
}

/* What a copy takes now (the first that applies). */
typedef enum { SEL_NONE, SEL_VALUE, SEL_LABEL, SEL_AREA, SEL_RANGE, SEL_PARTS, SEL_LINE } ClipSel;

static ClipSel clip_selection(View3d *v, GtkWidget *focus, GtkWidget **editor) {
    GtkWidget *ed = focus ? zg_setting_editor_of(focus) : NULL;
    if (ed) {
        *editor = ed;
        return SEL_VALUE;
    }
    ZgTool tool = zg_model_tool(v->model);
    if (tool == ZG_TOOL_LABEL && zg_label_tool_label(v->label)) return SEL_LABEL;
    if (tool == ZG_TOOL_SUPPORT && zg_support_has_selection(v->support)) return SEL_AREA;
    if (zg_range_card_open(zg_range_card_of(v->area))) return SEL_RANGE;
    guint n = 0;
    zg_model_parts(v->model, &n);
    if (n > 0) return SEL_PARTS;
    if (zg_model_selected(v->model) >= 0) return SEL_LINE;
    return SEL_NONE;
}

static gboolean clip_copy(View3d *v, ClipSel sel, GtkWidget *ed) {
    switch (sel) {
    case SEL_VALUE: {
        char *val = zg_setting_editor_value(ed);
        if (!val) return FALSE;
        /* The system clipboard too: a text field or another app takes it. */
        gdk_clipboard_set_text(gdk_display_get_clipboard(gtk_widget_get_display(v->area)), val);
        zg_clip_set_value(val);
        note(v, "Copied the value.");
        return TRUE;
    }
    case SEL_LABEL: {
        char *json = zg_label_tool_copy(v->label);
        if (!json) return FALSE;
        zg_clip_set_label(json, -1);
        note(v, "Copied the label.");
        return TRUE;
    }
    case SEL_AREA: {
        ZgSupportArea *a = zg_support_copy(v->support);
        if (!a) return FALSE;
        zg_clip_set_area(a);
        note(v, "Copied the support area.");
        return TRUE;
    }
    case SEL_RANGE: {
        GPtrArray *c = zg_model_scope_changes(v->model);
        if (c->len == 0) {
            g_ptr_array_unref(c);
            note(v, "These layers have no changes to copy.");
            return FALSE;
        }
        char *text = g_strdup_printf("Copied %u %s of the layers.", c->len, c->len == 1 ? "change" : "changes");
        zg_clip_set_range(c);
        note(v, text);
        g_free(text);
        return TRUE;
    }
    case SEL_PARTS: {
        guint n = 0;
        zg_model_parts(v->model, &n);
        if (!zg_model_parts_copy(v->model)) return FALSE;
        zg_clip_set_parts(FALSE);
        char *text = n == 1 ? g_strdup("Copied the part.") : g_strdup_printf("Copied %u parts.", n);
        note(v, text);
        g_free(text);
        return TRUE;
    }
    case SEL_LINE:
        on_copy_for_ai(NULL, NULL, v);
        note(v, "The report of the line is on the clipboard.");
        return TRUE;
    default:
        note(v, "Select a part, a label, a support area, or layers to copy.");
        return FALSE;
    }
}

/* A copy, then the selection goes (a setting and a line stay). */
static void clip_cut(View3d *v, ClipSel sel, GtkWidget *ed) {
    switch (sel) {
    case SEL_LABEL:
        if (clip_copy(v, sel, ed)) zg_label_tool_remove(v->label);
        return;
    case SEL_AREA:
        if (clip_copy(v, sel, ed)) zg_support_remove_selected(v->support);
        return;
    case SEL_RANGE:
        if (clip_copy(v, sel, ed)) zg_model_scope_clear(v->model, zg_clip_range());
        return;
    case SEL_PARTS: {
        guint n = 0;
        zg_model_parts(v->model, &n);
        if (!zg_model_parts_cut(v->model)) return;
        zg_clip_set_parts(FALSE);
        char *text = n == 1 ? g_strdup("Cut the part. Ctrl+V pastes it.") : g_strdup_printf("Cut %u parts. Ctrl+V pastes them.", n);
        note(v, text);
        g_free(text);
        return;
    }
    default:
        clip_copy(v, sel, ed);
    }
}

/* A copy next to the selection; the clipboard stays. */
static void clip_duplicate(View3d *v, ClipSel sel) {
    if (sel == SEL_PARTS) {
        zg_model_parts_duplicate(v->model);
    } else if (sel == SEL_LABEL) {
        char *json = zg_label_tool_copy(v->label);
        zg_label_tool_paste(v->label, json, FALSE, 0, 0, -1);
        g_free(json);
    } else {
        note(v, "Ctrl+D duplicates parts and labels.");
    }
}

static void on_value_text(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWidget *editor = data;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), res, NULL);
    if (text && !zg_setting_editor_set_value(editor, g_strstrip(text))) gtk_widget_error_bell(editor);
    g_free(text);
    g_object_unref(editor);
}

/* Pastes the clipboard. at: x, y (points of the view) is a place for it
 * (the pointer, or the right click). here: at x, y also with parts
 * selected (the context menu). as_plate: parts go onto a new plate. */
static void clip_paste(View3d *v, GtkWidget *ed, gboolean at, double x, double y, gboolean here, gboolean as_plate) {
    if (ed) {
        /* A setting: the text of the system clipboard (the copy of a
         * value put it there too). */
        gdk_clipboard_read_text_async(gdk_display_get_clipboard(gtk_widget_get_display(v->area)), NULL, on_value_text, g_object_ref(ed));
        return;
    }
    gboolean in3d = at && v->view && !v->hidden;
    switch (zg_clip_kind()) {
    case ZG_CLIP_PARTS:
    case ZG_CLIP_PLATE: {
        if (as_plate) {
            if (!zg_model_plate_paste_new(v->model)) note(v, "The plate did not paste.");
            return;
        }
        guint n = 0;
        zg_model_parts(v->model, &n);
        double bx = 0, by = 0;
        gboolean point = FALSE;
        if ((here || n == 0) && in3d) {
            int s = gtk_widget_get_scale_factor(v->area);
            point = zs_view_bed_point(v->view, (float)(x * s), (float)(y * s), &bx, &by);
        }
        if (zg_model_parts_paste(v->model, point, bx, by) < 0) note(v, "The parts did not paste.");
        else if (zs_app_plate_fits(zg_model_core(v->model)) != 1) note(v, "The parts do not all fit on the bed. Move some, or paste on another plate.");
        return;
    }
    case ZG_CLIP_LABEL: {
        gint64 part = -1;
        const char *json = zg_clip_label(&part);
        if (!v->view || v->hidden) {
            note(v, "Paste a label in the 3D view.");
            return;
        }
        zg_label_tool_paste(v->label, json, in3d, x, y, part);
        return;
    }
    case ZG_CLIP_AREA:
        if (!in3d || !zg_support_paste(v->support, zg_clip_area(), x, y)) note(v, "Point at a part to paste the support area there.");
        else note(v, "Pasted the support area.");
        return;
    case ZG_CLIP_RANGE:
        if (!zg_range_card_open(zg_range_card_of(v->area))) note(v, "Select layers first (drag up or down over the print), then paste the changes.");
        else zg_model_scope_paste(v->model, zg_clip_range());
        return;
    case ZG_CLIP_VALUE:
        note(v, "Click a setting, then paste the value into it.");
        return;
    default:
        note(v, "The clipboard is empty: copy a part, a label, a support area, or layers first.");
    }
}

/* The count of labels of part 0, for the log of a test. */
static int label_count(zs_app *core) {
    char buf[8192];
    size_t len = 0;
    if (zs_app_part_count(core) == 0 || zs_app_part_labels_get(core, 0, buf, sizeof buf, &len) != ZS_OK) return -1;
    int n = 0;
    for (const char *p = buf; (p = strstr(p, "\"origin\"")); p++) n++;
    return n;
}

gboolean zg_view3d_clip_key(GtkWidget *view, guint key, GdkModifierType mods, GtkWidget *focus) {
    View3d *v = view ? g_object_get_data(G_OBJECT(view), "zg-view3d") : NULL;
    if (!v || !(mods & GDK_CONTROL_MASK) || (mods & (GDK_ALT_MASK | GDK_SUPER_MASK))) return FALSE;
    if (focus && (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus))) return FALSE;
    gboolean shift = (mods & GDK_SHIFT_MASK) != 0;
    guint k = gdk_keyval_to_lower(key);
    if (k != GDK_KEY_c && k != GDK_KEY_x && k != GDK_KEY_v && k != GDK_KEY_d) return FALSE;
    if (shift && k != GDK_KEY_v) return FALSE;
    GtkWidget *ed = NULL;
    ClipSel sel = clip_selection(v, focus, &ed);
    if (k == GDK_KEY_v) clip_paste(v, sel == SEL_VALUE ? ed : NULL, v->pointer_in, v->pointer_x, v->pointer_y, FALSE, shift);
    else if (k == GDK_KEY_c) clip_copy(v, sel, ed);
    else if (k == GDK_KEY_x) clip_cut(v, sel, ed);
    else clip_duplicate(v, sel);
    /* The test hook: the state after the key, to the log. */
    if (g_getenv("ZSLICE_CLIP_LOG")) {
        zs_app *core = zg_model_core(v->model);
        guint n = 0;
        zg_model_parts(v->model, &n);
        g_message("clip: key %s, sel %d, clip %d, parts %zu, selected %u, plates %zu, label selected %d, labels of part 0 %d, overrides %zu", gdk_keyval_name(key), (int)sel, (int)zg_clip_kind(),
                  zs_app_part_count(core), n, zs_set_count(zg_model_plate_set(v->model)), zg_label_tool_label(v->label) ? 1 : 0, label_count(core), zs_app_override_count(core));
    }
    return TRUE;
}

/* The items of the context menu. */
static void on_paste_here(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    clip_paste(v, NULL, TRUE, v->menu_x, v->menu_y, TRUE, FALSE);
}

/* The part of the selected line becomes the selection. */
static gboolean select_line_part(View3d *v) {
    gint64 path = zg_model_selected(v->model);
    ptrdiff_t i = path >= 0 ? zs_app_part_of_path(zg_model_core(v->model), (size_t)path) : -1;
    if (i < 0) return FALSE;
    zg_model_select_part(v->model, i);
    return TRUE;
}

static void on_copy_part(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (select_line_part(v)) clip_copy(v, SEL_PARTS, NULL);
}

static void on_cut_part(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (select_line_part(v)) clip_cut(v, SEL_PARTS, NULL);
}

static void on_duplicate_part(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (select_line_part(v)) clip_duplicate(v, SEL_PARTS);
}

static void on_copy_plate(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (!zg_model_plate_copy(v->model)) {
        note(v, "The plate has no parts to copy.");
        return;
    }
    zg_clip_set_parts(TRUE);
    note(v, "Copied the plate.");
}

static void on_duplicate_plate(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    if (!zg_model_plate_duplicate(v->model)) note(v, "The plate has no parts to duplicate.");
}

static void on_paste_plate(GSimpleAction *a, GVariant *p, gpointer data) {
    View3d *v = data;
    clip_paste(v, NULL, FALSE, 0, 0, FALSE, TRUE);
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
    ZgClipKind clip = zg_clip_kind();
    if (clip != ZG_CLIP_EMPTY) {
        GMenu *paste = g_menu_new();
        GMenuItem *here = g_menu_item_new("Paste here", "view3d.paste-here");
        g_menu_item_set_attribute(here, "accel", "s", "<Control>v");
        g_menu_append_item(paste, here);
        g_object_unref(here);
        g_menu_append_section(menu, NULL, G_MENU_MODEL(paste));
        g_object_unref(paste);
    }
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
        /* The part of the line: copy, cut, duplicate. */
        GMenu *edit = g_menu_new();
        static const struct {
            const char *label, *action, *accel;
        } EDIT[] = {
            {"Copy the part", "view3d.copy-part", "<Control>c"},
            {"Cut the part", "view3d.cut-part", "<Control>x"},
            {"Duplicate the part", "view3d.duplicate-part", "<Control>d"},
        };
        for (size_t k = 0; k < G_N_ELEMENTS(EDIT); k++) {
            GMenuItem *it = g_menu_item_new(EDIT[k].label, EDIT[k].action);
            g_menu_item_set_attribute(it, "accel", "s", EDIT[k].accel);
            g_menu_append_item(edit, it);
            g_object_unref(it);
        }
        g_menu_append_section(menu, NULL, G_MENU_MODEL(edit));
        g_object_unref(edit);
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
        GMenu *copies = g_menu_new();
        g_menu_append(copies, "Copy the plate", "view3d.copy-plate");
        g_menu_append(copies, "Duplicate the plate", "view3d.duplicate-plate");
        if (clip == ZG_CLIP_PARTS || clip == ZG_CLIP_PLATE) {
            GMenuItem *it = g_menu_item_new("Paste as a new plate", "view3d.paste-plate");
            g_menu_item_set_attribute(it, "accel", "s", "<Control><Shift>v");
            g_menu_append_item(copies, it);
            g_object_unref(it);
        }
        g_menu_append_section(menu, NULL, G_MENU_MODEL(copies));
        g_object_unref(copies);
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

static void label_focus(gpointer data) {
    View3d *v = data;
    GtkWidget *preview = v->area;
    while (preview && !g_object_get_data(G_OBJECT(preview), "zg-preview")) preview = gtk_widget_get_parent(preview);
    if (preview) gtk_widget_grab_focus(preview);
}

static gint64 label_part_at(gpointer data, double x, double y) {
    View3d *v = data;
    return v->view ? part_at(v, x, y, NULL, NULL) : -1;
}

gboolean zg_view3d_label_key(GtkWidget *view, guint key) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && !v->hidden && zg_label_key(v->label, key);
}

gboolean zg_view3d_paint_key(GtkWidget *view, guint key) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return v && !v->hidden && zg_paint_key(v->paint, key);
}

GtkWidget *zg_view3d_paint_card(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return zg_paint_tool_card(v->paint);
}

GtkWidget *zg_view3d_label_card(GtkWidget *view) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    return zg_label_tool_card(v->label);
}

void zg_view3d_label_open(GtkWidget *view, gint64 part, guint32 id) {
    View3d *v = g_object_get_data(G_OBJECT(view), "zg-view3d");
    if (v) zg_label_tool_open(v->label, part, id);
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
    /* The Paint tool: two quick clicks paint two times; the view stays. */
    if (zg_model_tool(v->model) == ZG_TOOL_PAINT) return;
    if (look_at_side(v, x, y)) return;
    zs_view_reset_smooth(v->view);
    start_animation(v);
}

static void view_free(gpointer data) {
    View3d *v = data;
    g_signal_handlers_disconnect_by_data(v->model, v);
    if (v->idle) g_source_remove(v->idle);
    if (v->retry) g_source_remove(v->retry);
    if (v->scene_poll) g_source_remove(v->scene_poll);
    for (guint i = 0; v->hooks && i < v->hooks->len; i++)
        g_signal_handlers_disconnect_by_data(g_array_index(v->hooks, FrameHook, i).owner, v);
    if (v->hooks) g_array_free(v->hooks, TRUE);
    if (v->sign_rgba) g_bytes_unref(v->sign_rgba);
    g_free(v->sign_rects);
    if (v->group) g_array_free(v->group, TRUE);
    if (v->group_xy) g_array_free(v->group_xy, TRUE);
    zg_support_free(v->support);
    zg_label_tool_free(v->label);
    zg_paint_tool_free(v->paint);
    zg_part_meshes_free(v->meshes);
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
    v->meshes = zg_part_meshes_new(model);
    v->label = zg_label_tool_new(model, v->area, (ZgLabelHost){support_frame, label_focus, label_part_at, v}, v->meshes);
    v->paint = zg_paint_tool_new(model, v->area, (ZgPaintHost){support_frame, label_focus, v}, v->meshes);
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
    g_signal_connect(motion, "leave", G_CALLBACK(on_leave), v);
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
        {.name = "paste-here", .activate = on_paste_here},
        {.name = "copy-part", .activate = on_copy_part},
        {.name = "cut-part", .activate = on_cut_part},
        {.name = "duplicate-part", .activate = on_duplicate_part},
        {.name = "copy-plate", .activate = on_copy_plate},
        {.name = "duplicate-plate", .activate = on_duplicate_plate},
        {.name = "paste-plate", .activate = on_paste_plate},
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
