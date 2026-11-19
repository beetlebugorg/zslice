/* camera-view.h: the live picture of a printer camera, for the Printers
 * page.
 *
 * The sources:
 * - an MJPEG stream over HTTP (printdeck, OctoPrint, Moonraker): libsoup
 *   reads each part of the multipart reply;
 * - a snapshot over HTTP, read again every few seconds (a Moonraker camera
 *   with no MJPEG stream);
 * - a Bambu Lab printer (bambu-link.h): RTSP over TLS through GStreamer,
 *   or the JPEG frames of port 6000.
 * The picture goes from the printer straight to the app. A camera plays
 * only while it is active (zg_camera_view_set_active) and its widget is
 * mapped. The JPEG decode runs in a thread, and a frame that comes while
 * the last one decodes is dropped.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../prefs/printers.h"

G_BEGIN_DECLS

/* A new view with no source. large: the large view (a higher rate for a
 * snapshot, the whole picture of printdeck). */
GtkWidget *zg_camera_view_new(gboolean large);

/* An HTTP camera: stream (MJPEG, or NULL) and snapshot (or NULL), both
 * absolute. api_key: sent as X-Api-Key to the printer, or NULL. printdeck:
 * a tile asks for a small picture at a low rate (w= and fps=). */
void zg_camera_view_set_http(GtkWidget *view, const char *stream, const char *snapshot, const char *api_key,
                             gboolean printdeck);

/* The camera of a Bambu Lab printer (its address, serial, and access
 * code). model_id: the library id of the model, or NULL (then RTSPS,
 * and the JPEG port after a failure). */
void zg_camera_view_set_bambu(GtkWidget *view, const ZgPrinter *p, const char *model_id);

/* No camera: the view shows `message`. */
void zg_camera_view_set_none(GtkWidget *view, const char *message);

/* Plays while active and mapped; stops at once when not. */
void zg_camera_view_set_active(GtkWidget *view, gboolean active);

/* TRUE when the view has a source. */
gboolean zg_camera_view_has_source(GtkWidget *view);

G_END_DECLS
