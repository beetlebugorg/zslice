/* paint-tool.h: the Paint tool (P) of the 3D view, as web/app/paint.js.
 * It paints filaments on the surface of a part, for a print with more
 * than one filament.
 *
 * The tool shows the mesh of the part in place of the beads, each
 * triangle in the color of its filament (zs_view_paint_*). It paints the
 * selected part, or else the first part. Two modes:
 *
 * - Smart select: the region under the pointer lights before the click.
 *   A click paints the region with the filament of the card. A region is
 *   a part of the mesh that stands out of its surface or sinks into it (a
 *   raised letter: its top and its sides), else a flat or smooth face.
 *   Shift and a click add a region to the selection; a chip of another
 *   filament then paints all of it.
 * - Brush: a left drag paints a sphere of the brush size along the
 *   pointer. The triangles on the edge of the sphere split, so the border
 *   is clean.
 *
 * A right drag turns the view and a middle drag pans, as in the other
 * tools. Each hover and each step of the brush is a call to the paint
 * session of the part (zs_paint_*, from part-mesh.h) on the main thread,
 * with no wait. The end of a click or a stroke gives the paint to the part
 * (zg_model_part_paint_set): one step of the history, and a slice. An
 * undo or a redo gives the session the paint of the part again. The beads
 * show again when the tool closes. The card (paint-card.h) sits at the
 * left, next to the tools, so it never covers the part.
 *
 * view3d.c makes the tool, and sends it the presses, the drags, the
 * moves of the pointer, and the keys. All x, y are in logical points of
 * the 3D view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"
#include "part-mesh.h"

typedef struct ZgPaintTool ZgPaintTool;

/* The calls of the tool to its view: frame asks for a frame, and focus
 * gives the keys back to the view. */
typedef struct {
    void (*frame)(gpointer data);
    void (*focus)(gpointer data);
    gpointer data;
} ZgPaintHost;

typedef enum { ZG_PAINT_SMART = 0, ZG_PAINT_BRUSH = 1 } ZgPaintMode;

ZgPaintTool *zg_paint_tool_new(ZgModel *model, GtkWidget *area, ZgPaintHost host, ZgPartMeshes *meshes);
void zg_paint_tool_free(ZgPaintTool *t);
/* The core view, after the view starts. */
void zg_paint_tool_set_view(ZgPaintTool *t, zs_view *view);
/* The 3D view shows (TRUE) or hides: the card shows only with the view. */
void zg_paint_tool_set_shown(ZgPaintTool *t, gboolean shown);
/* The card. Add it to the overlay of the preview. */
GtkWidget *zg_paint_tool_card(ZgPaintTool *t);

/* A press of the left button at x, y with the tool on: TRUE if the tool
 * used it. Smart select paints the region there; the brush starts a
 * stroke. */
gboolean zg_paint_press(ZgPaintTool *t, double x, double y, gboolean shift);
void zg_paint_drag(ZgPaintTool *t, double x, double y);
/* The end of a press (also of a press that did not start here). */
void zg_paint_release(ZgPaintTool *t);
/* TRUE while a press of the tool lasts. */
gboolean zg_paint_pressed(ZgPaintTool *t);
/* The pointer at x, y with no button down: the region there lights. */
void zg_paint_hover(ZgPaintTool *t, double x, double y);
/* A key with the tool on: TRUE if the tool used it (Esc closes it). */
gboolean zg_paint_key(ZgPaintTool *t, guint key);

/* For the card. */
ZgPaintMode zg_paint_tool_mode(ZgPaintTool *t);
void zg_paint_tool_set_mode(ZgPaintTool *t, ZgPaintMode mode);
/* The radius of the brush, mm. */
double zg_paint_tool_size(ZgPaintTool *t);
void zg_paint_tool_set_size(ZgPaintTool *t, double mm);
/* The filament to paint with, and the filament of the part (from 1). */
int zg_paint_tool_filament(ZgPaintTool *t);
int zg_paint_tool_base(ZgPaintTool *t);
/* A new filament to paint with: the selection gets it too. */
void zg_paint_tool_set_filament(ZgPaintTool *t, int filament);
/* Adds a filament to the plate, and paints with it. */
void zg_paint_tool_add_filament(ZgPaintTool *t);
/* Remove all paint: the part prints with its own filament again. */
void zg_paint_tool_clear(ZgPaintTool *t);
