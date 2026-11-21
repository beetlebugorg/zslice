/* view3d.h: the 3D view of the toolpaths.
 *
 * Each path segment is a box: one line width wide, one layer height tall,
 * lit by a fixed light. The view shows the layers up to the layer that the
 * slider picks. Left drag to orbit, middle drag to pan, right drag to
 * rotate freely, scroll to zoom toward the pointer, and double-click to
 * reset the view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_view3d_new(ZgModel *model);

/* The time of the start of the process (g_get_monotonic_time), for
 * ZSLICE_BENCH. */
extern gint64 zg_start_us;

/* Moves the camera smoothly back to the start view (the Home key). */
void zg_view3d_reset(GtkWidget *view);
/* The origin of the bed of plate i in the world of the view (mm), for a
 * label over the plate. */
gboolean zg_view3d_plate_origin(GtkWidget *view, size_t i, double *x, double *y);
/* The plate under a point of the view (pixels), or -1. */
gint64 zg_view3d_plate_at(GtkWidget *view, double x, double y);
/* The signs of the plates (zs_view_set_signs): n rects (x, y, w, h) in an
 * RGBA image of width x height pixels (straight alpha), and the image
 * pixels for one device pixel of the view. The view keeps a reference. */
void zg_view3d_set_signs(GtkWidget *view, size_t n, const float *rects, guint width, guint height, GBytes *rgba, float scale);
/* Moves the camera smoothly to show all plates of the row (All). */
void zg_view3d_frame_all(GtkWidget *view);
/* TRUE while the view moves on its own: the camera animates, a part
 * falls, or the hand holds a part. */
gboolean zg_view3d_moving(GtkWidget *view);
/* The camera of the view, for a session restore (8 floats, see
 * zs_view_get_camera). Set: at once, or when the view starts. */
gboolean zg_view3d_get_camera(GtkWidget *view, float out[8]);
void zg_view3d_set_camera(GtkWidget *view, const float in[8]);

/* Ends the light of a range of layers (the card of the range closed): no
 * lit layers, and no lit body (zs_view_light_connected). */
void zg_view3d_light_clear(GtkWidget *view);
/* Shift+K (dir 1) and Shift+J (dir -1): the range of layers grows up or
 * down from the layer of the selected line, and its card opens. With a
 * selected line, the body of its part lights up; else all the lines of
 * the layers. */
void zg_view3d_key_range(GtkWidget *view, int dir);
/* The box of the beads on the bed (x0, y0, x1, y1 mm). FALSE if none. */
gboolean zg_view3d_bounds(GtkWidget *view, double out[4]);

/* Reads the toolpaths of the last slice from the core again. */
void zg_view3d_reload(GtkWidget *view);

/* The colors: enum zs_view_mode (the filament color, the features, or a
 * ramp of the speed, the flow, the layer time, or the line width). */
void zg_view3d_set_color_mode(GtkWidget *view, int mode);
/* The range of the ramp of a value mode (see zs_view_legend). */
gboolean zg_view3d_legend(GtkWidget *view, double *min, double *max);

/* Replay: shows the print at t seconds after the start (see
 * zs_view_set_time). */
void zg_view3d_set_time(GtkWidget *view, double t);
/* The replay length in seconds, or 0 if the view has no data. */
double zg_view3d_duration(GtkWidget *view);
/* The layer that the nozzle prints at time t. */
size_t zg_view3d_layer_at_time(GtkWidget *view, double t);

/* Shows the layers from 0 to `layer`. */
void zg_view3d_set_layer(GtkWidget *view, size_t layer);
/* Opens the context menu (support marks for the selected line, and the
 * view), in the middle of the view. */
void zg_view3d_context_menu(GtkWidget *view);
/* TRUE while the context menu is open (its keys are its own). */
gboolean zg_view3d_menu_open(GtkWidget *view);
/* A click of the measure tape at x, y (logical points): a point of the
 * print or the bed, or the center of a circle or an arc there. shift: no
 * snap. */
void zg_view3d_measure_click(GtkWidget *view, double x, double y, gboolean shift);
/* The pixel of a point of the world (mm) in the widget (logical points).
 * FALSE if it is behind the camera, or with no view. */
gboolean zg_view3d_pixel_of(GtkWidget *view, double x, double y, double z, double *px, double *py);
/* The box of path `path` on the screen, in points of the view (x0, y0,
 * x1, y1). FALSE if the 3D view does not show it. */
gboolean zg_view3d_path_rect(GtkWidget *view, gint64 path, double out[4]);
/* The hand of the Grab tool lets go of its part (Esc). FALSE if it holds
 * no part. */
gboolean zg_view3d_hand_release(GtkWidget *view);
/* The plane of a cut in the view (zs_view_set_cut); a box with no area
 * hides it. */
void zg_view3d_set_cut(GtkWidget *view, double x0, double y0, double x1, double y1, double z);
/* Calls fn(data) after each frame of the view (the cards that follow a
 * point of the print move then). The call stays while `owner` lives. */
void zg_view3d_on_frame(GtkWidget *view, GtkWidget *owner, void (*fn)(gpointer), gpointer data);
/* Shows the layers from lo to hi. */
void zg_view3d_set_layer_range(GtkWidget *view, size_t lo, size_t hi);
/* A key for the Support tool (support-tool.h): TRUE if it used the key. */
gboolean zg_view3d_support_key(GtkWidget *view, guint key);
/* The card of the Support tool, for the overlay of the preview. */
GtkWidget *zg_view3d_support_card(GtkWidget *view);
