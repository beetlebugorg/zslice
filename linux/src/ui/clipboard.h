/* clipboard.h: the clipboard of the app (as web/app/clipboard.js): the
 * last copy of Ctrl+C or Ctrl+X, for Ctrl+V. One for the process, so a
 * paste works in each window and on each plate.
 *
 * - Parts and a whole plate: the core keeps them (zs_app_parts_copy);
 *   this file keeps only the kind.
 * - A label: its JSON, and the part of the copy.
 * - A support area: a copy (support-tool.h).
 * - The changes of a range of layers: "name<TAB>value" lines.
 * - A setting value: its text. The system clipboard gets it too, so it
 *   pastes into a text field or another app.
 *
 * view3d.c (zg_view3d_clip) makes the copies and the pastes.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once
#include <gtk/gtk.h>

#include "support-tool.h"

typedef enum {
    ZG_CLIP_EMPTY = 0,
    ZG_CLIP_PARTS,
    ZG_CLIP_PLATE,
    ZG_CLIP_LABEL,
    ZG_CLIP_AREA,
    ZG_CLIP_RANGE,
    ZG_CLIP_VALUE,
} ZgClipKind;

ZgClipKind zg_clip_kind(void);
/* Each set replaces the copy before. The clipboard owns what it gets. */
void zg_clip_set_parts(gboolean plate);
void zg_clip_set_label(char *json, gint64 part);
void zg_clip_set_area(ZgSupportArea *area);
void zg_clip_set_range(GPtrArray *changes);
void zg_clip_set_value(char *text);
/* The copy of a kind, or NULL for another kind. */
const char *zg_clip_label(gint64 *part);
const ZgSupportArea *zg_clip_area(void);
GPtrArray *zg_clip_range(void);
const char *zg_clip_value(void);
