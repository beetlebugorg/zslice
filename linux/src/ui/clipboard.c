/* clipboard.c: the clipboard of the app (see clipboard.h).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "clipboard.h"

static struct {
    ZgClipKind kind;
    char *text; /* a label (JSON) or a value */
    gint64 part;
    ZgSupportArea *area;
    GPtrArray *range;
} clip;

static void clip_clear(void) {
    g_clear_pointer(&clip.text, g_free);
    g_clear_pointer(&clip.area, g_free);
    g_clear_pointer(&clip.range, g_ptr_array_unref);
    clip.part = -1;
    clip.kind = ZG_CLIP_EMPTY;
}

ZgClipKind zg_clip_kind(void) {
    return clip.kind;
}

void zg_clip_set_parts(gboolean plate) {
    clip_clear();
    clip.kind = plate ? ZG_CLIP_PLATE : ZG_CLIP_PARTS;
}

void zg_clip_set_label(char *json, gint64 part) {
    clip_clear();
    clip.kind = ZG_CLIP_LABEL;
    clip.text = json;
    clip.part = part;
}

void zg_clip_set_area(ZgSupportArea *area) {
    clip_clear();
    clip.kind = ZG_CLIP_AREA;
    clip.area = area;
}

void zg_clip_set_range(GPtrArray *changes) {
    clip_clear();
    clip.kind = ZG_CLIP_RANGE;
    clip.range = changes;
}

void zg_clip_set_value(char *text) {
    clip_clear();
    clip.kind = ZG_CLIP_VALUE;
    clip.text = text;
}

const char *zg_clip_label(gint64 *part) {
    if (clip.kind != ZG_CLIP_LABEL) return NULL;
    if (part) *part = clip.part;
    return clip.text;
}

const ZgSupportArea *zg_clip_area(void) {
    return clip.kind == ZG_CLIP_AREA ? clip.area : NULL;
}

GPtrArray *zg_clip_range(void) {
    return clip.kind == ZG_CLIP_RANGE ? clip.range : NULL;
}

const char *zg_clip_value(void) {
    return clip.kind == ZG_CLIP_VALUE ? clip.text : NULL;
}
