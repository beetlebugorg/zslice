/* native-surface.h: a native window-system surface under the GTK window,
 * for the 3D view.
 *
 * The core draws the 3D view with Vulkan, and Vulkan needs a real
 * window-system surface. GTK4 gives none for one widget. So the view gets
 * its own Wayland subsurface, placed BELOW the GTK window, at the position
 * of the view widget. The widget draws nothing, so the window has a
 * transparent hole there, and the compositor shows the subsurface through
 * it. The subsurface has an empty input region, so the pointer events go to
 * the GTK widget.
 *
 * Adapted from linux/src/engine/surface.c of Lookout Marine (same author,
 * MIT license, see REFERENCES.md). This version supports Wayland. X11 is
 * on the roadmap.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "zslice-app.h"

typedef struct _ZgNativeSurface ZgNativeSurface;

/* Makes the surface under `parent`, at (x, y) in logical points, with an
 * integer scale. NULL with *error if the GDK backend has no way to do it. */
ZgNativeSurface *zg_native_surface_new(GdkSurface *parent, int x, int y, int scale, GError **error);
void zg_native_surface_free(ZgNativeSurface *self);

/* The description of the surface for zs_view_new. */
const zs_surface *zg_native_surface_handle(ZgNativeSurface *self);

/* Moves the surface. */
void zg_native_surface_move(ZgNativeSurface *self, int x, int y, int scale);

/* Hides the surface until the next frame. */
void zg_native_surface_hide(ZgNativeSurface *self);
